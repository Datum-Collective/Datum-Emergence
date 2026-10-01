#!/bin/sh
# Interactive installer test: boot the ISO through GRUB/OVMF, drive the real
# datum-install TUI (menu, keyboard, account with invalid-username and
# password-mismatch retries, hostname, timezone, summary, disk, destructive
# confirmation) via the QEMU monitor exactly like a human would, install to
# a blank virtual disk, power off from the installer menu, and verify the
# target on the host (loop mount, read-only).
#
# Usage:
#   sudo ./scripts/test-installer-tui.sh [--iso PATH] [--disk-size GB] [--wait SECS] [--keep]
#
# Requires root (loop-mount of the installed target), qemu-system-x86_64
# (KVM or TCG fallback), OVMF firmware, qemu-img, and python3. Test
# credentials are [a-z0-9] only (QEMU sendkey mapping) and live solely in
# this invocation; they are never written into the image.
#
# WARNING: DESTRUCTIVE to the scratch disk image it creates (a temp file,
# removed unless --keep). It never touches host disks. The ISO drive is
# attached read-only so even a disk-selection bug cannot harm it.
set -eu

ISO="$PWD/dist/emergence-amd64.iso"
DISK_SIZE_GB=20
WAIT=1500
KEEP=no
WORKDIR=""

while test $# -gt 0; do
  case "$1" in
    --iso) ISO=$2; shift 2 ;;
    --disk-size) DISK_SIZE_GB=$2; shift 2 ;;
    --wait) WAIT=$2; shift 2 ;;
    --keep) KEEP=yes; shift ;;
    -h|--help)
      printf '%s\n' "usage: test-installer-tui.sh [--iso PATH] [--disk-size GB] [--wait SECS] [--keep]" >&2
      exit 2 ;;
    *) printf '%s\n' "test-installer-tui: unknown option $1" >&2; exit 2 ;;
  esac
done

test -s "$ISO" || { printf '%s\n' "test-installer-tui: ISO not found: $ISO" >&2; exit 1; }
test "$(id -u)" -eq 0 || { printf '%s\n' "test-installer-tui: run as root (loop-mounts the target)" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || { printf '%s\n' 'test-installer-tui: qemu-system-x86_64 is required.' >&2; exit 1; }
command -v qemu-img >/dev/null 2>&1 || { printf '%s\n' 'test-installer-tui: qemu-img is required.' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf '%s\n' 'test-installer-tui: python3 is required.' >&2; exit 1; }

accel=tcg
cpu=max
if test -r /dev/kvm -a -w /dev/kvm; then accel=kvm; cpu=host; fi

OVMF_CODE=""
for candidate in /usr/share/edk2-ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
  if test -r "$candidate"; then OVMF_CODE=$candidate; break; fi
done
test -n "$OVMF_CODE" || { printf '%s\n' 'test-installer-tui: OVMF firmware not found (sys-firmware/edk2-bin).' >&2; exit 1; }
# Disk-pressure guard: the scratch image is sparse but the install writes
# several GB of real blocks into it, and the workdir lives on /tmp (often a
# small tmpfs). A previous failed run left its workdir behind often enough
# that a mysterious mid-install failure was eventually traced to a full
# /tmp, so fail fast with a clear message instead of a flaky engine fatal.
# 6 GiB floor covers the ~5 GiB a completed install really occupies.
if test "$(df -k /tmp 2>/dev/null | awk 'NR==2{print $4}')" -lt 6291456; then
  printf '%s\n' 'test-installer-tui: less than 6GiB free on /tmp; clear stale /tmp/emergence-installer-tui-* workdirs first.' >&2
  exit 1
fi

WORKDIR=$(mktemp -d /tmp/emergence-installer-tui-XXXXXX)
cleanup() { rm -rf "$WORKDIR"; }
trap 'cleanup' EXIT INT TERM

DISK="$WORKDIR/target.raw"
qemu-img create -f raw "$DISK" "${DISK_SIZE_GB}G" >/dev/null
VARS="$WORKDIR/ovmf-vars.fd"
cp -f "$(dirname "$OVMF_CODE")/OVMF_VARS.fd" "$VARS" 2>/dev/null || dd if=/dev/zero of="$VARS" bs=1M count=4 2>/dev/null
SERIAL="$WORKDIR/tui-serial.log"
MON="$WORKDIR/tui-mon.sock"
: > "$SERIAL"
rm -f "$MON"

# The ISO is read-only: even a disk-selection bug in the TUI cannot destroy
# the test medium itself (the engine would still refuse it loudly).
qemu-system-x86_64 -m 4096 -smp 4 -accel "$accel" -cpu "$cpu" \
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
  -drive "if=pflash,format=raw,file=$VARS" \
  -drive "file=$ISO,media=cdrom,if=virtio,readonly=on" \
  -drive "file=$DISK,format=raw,if=virtio" \
  -boot order=d -display none -serial "file:$SERIAL" -monitor "unix:$MON,server,nowait" &
QEMU_PID=$!
# Unbuffered (`-u`) so the work log streams live; the `|| RC=$?` captures
# the driver status without tripping `set -e` (a bare `RC=$?` on the next
# line would never run: errexit fires on the failing python first, skipping
# the verdict tail and cleaning the workdir -- the silent-failure signature
# this harness once had; see the comment at the tail).
RC=0
python3 -u - "$MON" "$SERIAL" "$WAIT" <<'PYEOF' || RC=$?
import socket, sys, time
mon_sock, serial_log, wait = sys.argv[1], sys.argv[2], int(sys.argv[3])
user, pw, host = "tuiuser", "tuipass123", "tuitest"
m = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
m.settimeout(15)
for _ in range(60):
    try:
        m.connect(mon_sock)
        break
    except (FileNotFoundError, ConnectionRefusedError):
        time.sleep(2)
else:
    print("FATAL: no monitor")
    sys.exit(1)
m.settimeout(10)
try:
    m.recv(4096)
except socket.timeout:
    pass
def pump():
    m.settimeout(0)
    try:
        while True:
            chunk = m.recv(65536)
            if not chunk:
                break
    except (socket.timeout, BlockingIOError, OSError):
        pass
    finally:
        m.settimeout(10)
def sendkey(keys):
    try:
        m.sendall(("sendkey %s\r" % keys).encode())
    except (BrokenPipeError, OSError) as e:
        print("FATAL: monitor send failed: %s" % e)
        sys.exit(1)
    pump()
def stype(text, delay=0.7):
    for ch in text:
        sendkey("spc" if ch == ' ' else ch)
        time.sleep(delay)
    sendkey("ret")
    time.sleep(1.5)
def wait_serial(marker, timeout):
    end = time.time() + timeout
    while time.time() < end:
        try:
            with open(serial_log, errors="replace") as f:
                if marker in f.read():
                    return True
        except OSError:
            pass
        time.sleep(5)
    return False
def need(marker, timeout, what):
    if not wait_serial(marker, timeout):
        print("FATAL: %s (missing %r)" % (what, marker))
        sys.exit(1)
def stype_need(text, marker, what, timeout=180):
    # Type one input, then require its follow-up marker. The QEMU monitor
    # delivery is occasionally lossy, so on timeout the input is typed once
    # more while its prompt is (by construction) still waiting; a second
    # timeout is a real failure, not a flake. Retries can only mis-pair if
    # the first attempt partially arrived, in which case the confirmation
    # identity check below fails loudly instead of installing blindly.
    stype(text)
    if wait_serial(marker, 120):
        return
    print("retry: %r (missing %r)" % (text, marker), flush=True)
    stype(text)
    need(marker, timeout, what)
def stype_pair_need(first, second, marker, what, timeout=180):
    stype(first)
    time.sleep(2)
    stype(second)
    if wait_serial(marker, 120):
        return
    print("retry pair (missing %r)" % marker, flush=True)
    stype(first)
    time.sleep(2)
    stype(second)
    need(marker, timeout, what)
# Menu -> Install -> welcome.
need("Datum installer: menu", wait, "installer menu never appeared")
stype("1")
need("Datum installer: welcome", 180, "welcome never appeared")
stype_need("", "Datum installer: configure keyboard", "keyboard step never started", timeout=300)
# Keyboard (lowercase name, typed).
stype_need("us", "Datum installer: configure account", "account step never started")
# Account: invalid username first (must be rejected), then the real one;
# then a password mismatch (must be rejected), then the real password twice.
stype_need("1bad", "Datum installer: invalid username rejected", "invalid username not rejected")
stype(user)
time.sleep(2)
stype_pair_need("aaa111", "aaa222", "Datum installer: password mismatch", "password mismatch not detected")
time.sleep(2)
stype_pair_need(pw, pw, "Datum installer: configure hostname", "hostname step never started")
# Hostname (typed), timezone (default UTC accepted with bare Enter:
# zoneinfo names are case-sensitive and the monitor mapping is lowercase),
# summary (default Continue).
stype_need(host, "Datum installer: configure timezone", "timezone step never started")
stype_need("", "Datum installer: summary", "summary never appeared")
stype_need("", "Datum installer: configure disk", "disk step never started")
# Disk: the ISO drive must be hidden, so the blank disk is [1].
stype("1")
# Confirmation marker carries the chosen disk AND the configured identity:
# refuse to proceed unless it names the blank disk and the exact username and
# hostname (this also proves no keystroke was mis-paired into another field).
if not wait_serial("Datum installer: confirm (disk=/dev/vdb user=tuiuser host=tuitest", 180):
    print("retry disk choice", flush=True)
    stype("1")
    if not wait_serial("Datum installer: confirm (disk=/dev/vdb user=tuiuser host=tuitest", 300):
        print("FATAL: confirmation did not name the blank disk and identity (wrong target?)")
        sys.exit(1)
stype_need("yes", "Datum installer: engine start", "installation engine never started")
need("Datum installer: install success", wait, "installation did not succeed")
time.sleep(10)
stype("n")  # success screen: do not reboot; back to menu
need("Datum installer: menu", 300, "installer menu never returned")
stype("4")  # power off from the menu
print("TUI DRIVE DONE")
PYEOF
printf '%s\n' "test-installer-tui: driver RC=$RC" >&2
# Poweroff from the guest ends QEMU; wait for the exit, then force it.
for _ in $(seq 1 24); do
  kill -0 "$QEMU_PID" 2>/dev/null || break
  sleep 5
done
kill "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true
# Forensics on driver failure only: copy the virtual disk and the serial
# transcript next to the invoking directory BEFORE the verdict branch, so a
# stall can always be autopsied from the install log and target state.
# (Success needs no forensics: the PASS lines plus the kept/failing workdir
# on other branches are the evidence; a 6 GiB copy per green run would just
# pile up.) `$DISK` is sparse but carries several GiB of real blocks.
if test "$RC" -ne 0; then
  FORENSIC_DIR="$PWD/emergence-tui-forensic-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$FORENSIC_DIR" 2>/dev/null || true
  cp --sparse=always -f "$DISK" "$FORENSIC_DIR/target.raw" 2>/dev/null || true
  cp -f "$SERIAL" "$FORENSIC_DIR/tui-serial.log" 2>/dev/null || true
  printf '%s\n' "test-installer-tui: forensics copied to $FORENSIC_DIR" >&2
fi
if test "$RC" -ne 0; then
  trap - EXIT INT TERM
  printf '%s\n' "test-installer-tui: FAIL: TUI drive failed; workdir kept at $WORKDIR" >&2
  exit 1
fi
printf '%s\n' 'test-installer-tui: TUI drive completed; verifying target on host.' >&2
# The live boot itself must have been healthy: probe completed, live marker
# present, installer service active, and no login session on live media.
for want in 'DATUM_PROBE end' 'DATUM_PROBE installer.live-marker=present' \
    'DATUM_PROBE service.datum-installer.service=active' \
    'DATUM_PROBE user.session=no(live-installer)'; do
  if ! grep -q "$want" "$SERIAL" 2>/dev/null; then
    trap - EXIT INT TERM
    printf '%s\n' "test-installer-tui: FAIL: live boot unhealthy (missing $want; kept at $WORKDIR)" >&2
    exit 1
  fi
done

TGT="$WORKDIR/tgt"
mkdir -p "$TGT"
if ! mount -o loop,ro,offset=$((1050624 * 512)) "$DISK" "$TGT"; then
  trap - EXIT INT TERM
  printf '%s\n' "test-installer-tui: FAIL: cannot mount target root (kept at $WORKDIR)" >&2
  exit 1
fi
FAIL=0
tcheck() {
  desc=$1; shift
  if "$@" >/dev/null 2>&1; then
    printf '%s\n' "test-installer-tui: target PASS: $desc" >&2
  else
    printf '%s\n' "test-installer-tui: target FAIL: $desc" >&2
    FAIL=1
  fi
}
tcheck "installed marker present" test -e "$TGT/etc/datum/installed"
tcheck "no live marker" test "!" -e "$TGT/etc/datum/live"
tcheck "permanent user exists" grep -q '^tuiuser:' "$TGT/etc/passwd"
tcheck "user home owned by user (numeric UID: names resolve against the host, not the target)" test "$(stat -c %u "$TGT/home/tuiuser" 2>/dev/null)" = "$(awk -F: '$1=="tuiuser"{print $3}' "$TGT/etc/passwd")"
tcheck "hostname correct" grep -qx 'tuitest' "$TGT/etc/hostname"
tcheck "timezone is UTC" test "$TGT/etc/localtime" -ef /usr/share/zoneinfo/UTC
tcheck "tuigreet default session" grep -q '^\[default_session\]' "$TGT/etc/greetd/config.toml"
tcheck "no initial_session autologin" test -z "$(grep '^\[initial_session\]' "$TGT/etc/greetd/config.toml" || true)"
tcheck "no live installer unit" test "!" -e "$TGT/etc/systemd/system/datum-installer.service"
tcheck "no live installer binary" test "!" -e "$TGT/usr/local/bin/datum-install"
umount "$TGT" || FAIL=1
if test "$FAIL" -ne 0; then
  trap - EXIT INT TERM
  printf '%s\n' "test-installer-tui: FAIL: target verification failed (workdir kept at $WORKDIR)" >&2
  exit 1
fi
# Passwords must never appear in guest output (prompts mask them; markers
# never carry values).
if grep -q 'tuipass123\|aaa111\|aaa222' "$SERIAL" 2>/dev/null; then
  trap - EXIT INT TERM
  printf '%s\n' 'test-installer-tui: FAIL: password leaked into serial log.' >&2
  exit 1
fi
if test "$KEEP" = yes; then
  trap - EXIT INT TERM
  printf '%s\n' "test-installer-tui: keeping $DISK and $SERIAL" >&2
  cp "$DISK" ./emergence-tui-test-disk.raw
  cp "$SERIAL" ./emergence-tui-test-serial.log
fi
rm -rf "$WORKDIR"
trap - EXIT INT TERM
printf '%s\n' 'test-installer-tui: PASS: interactive installer installs a clean target.' >&2
exit 0
