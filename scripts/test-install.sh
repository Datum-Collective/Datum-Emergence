#!/bin/sh
# End-to-end installer test: boot the ISO, install to a blank virtual disk,
# reboot from the installed disk, and verify the installed Emergence system.
#
# Usage:
#   ./scripts/test-install.sh [--iso PATH] [--disk-size GB] [--wait SECS] [--keep]
#
# Requires qemu-system-x86_64 with KVM (or TCG fallback), OVMF firmware for
# the live boot, and python3 for the serial-console driver. The install runs
# with init=/bin/sh (no login needed); the installed system is verified
# through the in-image datum-boot-probe markers on its own serial console.
#
# WARNING: fully automated and DESTRUCTIVE to the scratch disk image it
# creates (a temp file, removed unless --keep). It never touches host disks:
# the installer only ever sees the QEMU virtual disk.
set -eu

ISO="$PWD/dist/emergence-amd64.iso"
DISK_SIZE_GB=20
WAIT=600
KEEP=no
WORKDIR=""

while test $# -gt 0; do
  case "$1" in
    --iso) ISO=$2; shift 2 ;;
    --disk-size) DISK_SIZE_GB=$2; shift 2 ;;
    --wait) WAIT=$2; shift 2 ;;
    --keep) KEEP=yes; shift ;;
    -h|--help)
      printf '%s\n' "usage: test-install.sh [--iso PATH] [--disk-size GB] [--wait SECS] [--keep]" >&2
      exit 2 ;;
    *) printf '%s\n' "test-install: unknown option $1" >&2; exit 2 ;;
  esac
done

test -s "$ISO" || { printf '%s\n' "test-install: ISO not found: $ISO" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || { printf '%s\n' 'test-install: qemu-system-x86_64 is required.' >&2; exit 1; }
command -v qemu-img >/dev/null 2>&1 || { printf '%s\n' 'test-install: qemu-img is required.' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf '%s\n' 'test-install: python3 is required.' >&2; exit 1; }

accel=tcg
cpu=max
if test -r /dev/kvm -a -w /dev/kvm; then accel=kvm; cpu=host; fi

OVMF_CODE=""
for candidate in /usr/share/edk2-ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
  if test -r "$candidate"; then OVMF_CODE=$candidate; break; fi
done
test -n "$OVMF_CODE" || { printf '%s\n' 'test-install: OVMF firmware not found (sys-firmware/edk2-bin).' >&2; exit 1; }

WORKDIR=$(mktemp -d /tmp/emergence-install-test-XXXXXX)
cleanup() { rm -rf "$WORKDIR"; }
trap 'cleanup' EXIT INT TERM

DISK="$WORKDIR/target.raw"
# Inside the guest the image appears as the second virtio disk. The installer
# must be pointed at the guest device node, never at the host image path.
GUEST_DISK=/dev/vdb
GUEST_DISK_BYTES=$((DISK_SIZE_GB * 1024 * 1024 * 1024))
qemu-img create -f raw "$DISK" "${DISK_SIZE_GB}G" >/dev/null
xorriso -indev "$ISO" -osirrox on \
  -extract /boot/gentoo "$WORKDIR/gentoo" \
  -extract /boot/gentoo.igz "$WORKDIR/gentoo.igz" >/dev/null 2>&1
MON_SOCK="$WORKDIR/mon.sock"

# Phase A: live boot with a root shell, run the installer, power off.
# Firmware note: this phase boots the extracted kernel directly (-kernel
# with init=/bin/sh for a root shell without any login). OVMF silently
# ignores -kernel/-initrd/-append (UEFI firmware only boots BootOrder
# devices, so the guest would boot GRUB into the firstboot prompt instead
# of the intended root shell), while SeaBIOS honors direct kernel boot.
# Phase A therefore uses the default SeaBIOS firmware on purpose; Phase B
# still boots the installed disk through OVMF, so UEFI bootloader coverage
# is preserved where it matters.
#
# Console note: guest output goes to a FILE serial log (the unix-socket
# serial backend delivered zero bytes on this host), and input is typed
# through the QEMU monitor (sendkey), exactly like the firstboot harness.
# Only unshifted keys are ever typed ([a-z0-9] plus space / - = . , ;),
# so no shift-combo flakiness; every typed line ends with its own
# "; echo <tag>" completion marker.
TRANSCRIPT="$PWD/emergence-install-serial-live.log"
rm -f "$TRANSCRIPT"
qemu-system-x86_64 -m 4096 -smp 4 -accel "$accel" -cpu "$cpu" \
  -drive "file=$ISO,media=cdrom,if=virtio" \
  -drive "file=$DISK,format=raw,if=virtio" \
  -kernel "$WORKDIR/gentoo" -initrd "$WORKDIR/gentoo.igz" \
  -append "root=live:CDLABEL=DATUM_EMERGENCE_AMD64 rd.live.dir=/ rd.live.squashimg=image.squashfs cdroot console=ttyS0,115200 init=/bin/sh" \
  -display none -serial "file:$TRANSCRIPT" -monitor "unix:$MON_SOCK,server,nowait" &
QEMU_A=$!
python3 - "$MON_SOCK" "$TRANSCRIPT" "$GUEST_DISK" "$GUEST_DISK_BYTES" <<'PYEOF'
import socket, sys, time
mon_sock, serial_log, disk, disk_bytes = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
def read_serial():
    try:
        with open(serial_log, errors="replace") as f:
            return f.read()
    except OSError:
        return ""
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
    # Drain monitor responses without blocking: an unread monitor stalls
    # QEMU command processing.
    m.settimeout(0)
    try:
        while True:
            if not m.recv(65536):
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
# Only unshifted keys: QEMU monitor shift-combos are unreliable here.
KEYS = {' ': 'spc', '/': 'slash', '-': 'minus', '=': 'equal',
        '.': 'dot', ',': 'comma', ';': 'semicolon'}
def stype(text, delay=0.2):
    for ch in text:
        sendkey(KEYS.get(ch, ch))
        time.sleep(delay)
    sendkey("ret")
    time.sleep(0.5)
fails = []
mark = 0
def check(cond, what):
    print(("PASS " if cond else "FAIL ") + what, flush=True)
    if not cond:
        fails.append(what)
def wait_count(needle, n, timeout):
    # needle occurrences since mark (mark = file size when the line was
    # typed). A typed line appears once as tty echo; real command output
    # adds further occurrences, so completion tags need >= 2 (echo +
    # execution) while data absent from the input needs >= 1.
    end = time.time() + timeout
    while time.time() < end:
        pump()
        try:
            with open(serial_log, errors="replace") as f:
                f.seek(mark)
                if f.read().count(needle) >= n:
                    return True
        except OSError:
            pass
        time.sleep(5)
    return False
def run_typed(cmd, tag, timeout=180):
    # Type "<cmd> ; echo <tag>" and wait for the tag's execution (echo +
    # output = 2 occurrences after the typing position).
    global mark
    try:
        mark = open(serial_log, "rb").seek(0, 2)
    except OSError:
        mark = 0
    stype(cmd + " ; echo " + tag)
    return wait_count(tag, 2, timeout)
# 1. Cold boots (dracut live assembly, empty caches) can take minutes to
# reach init; poll patiently rather than failing fast.
check(wait_count("sh-5.3#", 1, 300), "guest reached root shell")
if fails:
    sys.exit(1)
# 2. Wrong-disk guard: the guest target must be exactly the expected size,
# and must be the disk we created (never the host's).
if run_typed("ls /dev/vdb", "t1done"):
    check(wait_count("/dev/vdb", 2, 60), "target disk visible")
else:
    check(False, "target disk visible")
if run_typed("lsblk -b /dev/vdb", "t2done", 60):
    check(wait_count(str(disk_bytes), 1, 60), "target disk size exact")
else:
    check(False, "target disk size exact")
# 3. Simulate the live firstboot lifecycle. This phase boots with
# init=/bin/sh (no systemd), so datum-firstboot-live never runs; create
# exactly what it would have created: a real local account, a home, and
# both live-user markers (persistent /etc one + runtime /run one). The
# installer must then remove that live-only identity from the target.
# Supplementary groups come from the live /etc/group (parsed here, not in
# the guest) so the command stays free of shell metacharacters.
if run_typed("cat /etc/group", "t3done", 60):
    present = [g for g in ("wheel", "audio", "video", "render", "input",
                           "plugdev", "cdrom")
               if g + ":x:" in read_serial()]
    uacmd = "useradd -m -g users -s /bin/bash livetemp"
    if present:
        uacmd = "useradd -m -g users -G " + ",".join(present) + " -s /bin/bash livetemp"
    if run_typed(uacmd, "t4done", 120):
        check(wait_count("t4done", 2, 60), "live user created")
    else:
        check(False, "live user created")
else:
    check(False, "live user created")
if run_typed("getent passwd livetemp", "t5done", 60):
    check(wait_count("livetemp", 2, 60), "live user resolvable")
else:
    check(False, "live user resolvable")
if not run_typed("mkdir -p /etc/datum", "t6done", 60):
    check(False, "marker dir created")
# Marker files via dd with an exact byte count (no shell redirects, which
# need unshifted-unreliable keys): "livetemp\n" is 9 bytes; the trailing
# ret completes the count and dd exits, then the echo tag runs.
for marker, tag in (("/etc/datum/live-user", "t7done"),
                    ("/run/datum-live-user", "t8done")):
    try:
        mark = open(serial_log, "rb").seek(0, 2)
    except OSError:
        mark = 0
    stype("dd of=" + marker + " bs=1 count=9 ; echo " + tag)
    time.sleep(2)
    stype("livetemp")
    check(wait_count(tag, 2, 120), "marker written: " + marker)
if run_typed("cat /etc/datum/live-user", "t9done", 60):
    check(wait_count("livetemp", 2, 60), "marker readable")
else:
    check(False, "marker readable")
if fails:
    sys.exit(1)
# 4. Run the installer with an interactive password (the real user path:
# no environment backdoors here). The installer prints its plan, then
# prompts twice; the typed password is masked by the guest tty.
stype("datum-install --disk " + disk + " --user datum --hostname emergencetest --yes")
check(wait_count("password for datum", 1, 300), "installer reached password prompt")
if not fails:
    stype("emergencetestpass")
    check(wait_count("repeat password", 1, 120), "installer asked for confirmation")
if not fails:
    stype("emergencetestpass")
    check(wait_count("installed Datum Emergence", 1, 1500), "installation completed")
print("PHASE-A %s" % ("SUCCESS" if not fails else "FAILED"))
sys.exit(0 if not fails else 1)
PYEOF
RC=$?
kill "$QEMU_A" 2>/dev/null || true
wait "$QEMU_A" 2>/dev/null || true
if test "$RC" -ne 0; then
  # Keep the workdir for forensics (trap disarmed); the file-serial
  # transcript already lives in the invoking directory.
  trap - EXIT INT TERM
  printf '%s\n' "test-install: FAIL: Phase A did not complete; workdir kept at $WORKDIR" >&2
  exit 1
fi
printf '%s\n' 'test-install: Phase A completed; verifying target on host.' >&2
# Host-side target verification (read-only loop mount of the installed
# root): the live-only account and its marker must be gone, the permanent
# user and its installed autologin must exist, and no live-firstboot files
# may linger. Partition layout is fixed by the installer: p1 starts at
# sector 2048 (512M ESP), p2 at sector 1050624 (rest, ext4 root).
TGT="$WORKDIR/tgt"
mkdir -p "$TGT"
if ! mount -o loop,ro,offset=$((1050624 * 512)) "$DISK" "$TGT"; then
  trap - EXIT INT TERM
  printf '%s\n' "test-install: FAIL: cannot mount target root (kept at $WORKDIR)" >&2
  exit 1
fi
FAIL=0
tcheck() {
  # $1 = description, rest = test command (negated where needed by caller).
  desc=$1; shift
  if "$@" >/dev/null 2>&1; then
    printf '%s\n' "test-install: target PASS: $desc" >&2
  else
    printf '%s\n' "test-install: target FAIL: $desc" >&2
    FAIL=1
  fi
}
tcheck "no live marker" test "!" -e "$TGT/etc/datum/live-user"
tcheck "no live passwd entry" test -z "$(grep '^livetemp:' "$TGT/etc/passwd" || true)"
tcheck "no live shadow entry" test -z "$(grep '^livetemp:' "$TGT/etc/shadow" || true)"
tcheck "no live group membership" test -z "$(grep 'livetemp' "$TGT/etc/group" || true)"
tcheck "no live home" test "!" -e "$TGT/home/livetemp"
tcheck "permanent user exists" grep -q '^datum:' "$TGT/etc/passwd"
tcheck "installed autologin present" grep -q 'initial_session' "$TGT/etc/greetd/config.toml"
tcheck "installed autologin user" grep -q 'user = "datum"' "$TGT/etc/greetd/config.toml"
tcheck "no live firstboot unit" test "!" -e "$TGT/etc/systemd/system/datum-firstboot-live.service"
tcheck "no live firstboot script" test "!" -e "$TGT/usr/local/bin/datum-firstboot-live"
tcheck "no legacy cleanup unit" test "!" -e "$TGT/etc/systemd/system/datum-firstboot.service"
umount "$TGT" || FAIL=1
if test "$FAIL" -ne 0; then
  trap - EXIT INT TERM
  printf '%s\n' "test-install: FAIL: target verification failed (workdir kept at $WORKDIR)" >&2
  exit 1
fi
printf '%s\n' 'test-install: installation completed; booting installed disk.' >&2

# Phase B: boot the installed disk through its own bootloader, verify probe.
VARS_B="$WORKDIR/ovmf-vars-b.fd"
cp -f "$(dirname "$OVMF_CODE")/OVMF_VARS.fd" "$VARS_B" 2>/dev/null || dd if=/dev/zero of="$VARS_B" bs=1M count=4 2>/dev/null
SERIAL_B="$WORKDIR/installed-serial.log"
: > "$SERIAL_B"
qemu-system-x86_64 -m 4096 -smp 4 -accel "$accel" -cpu "$cpu" \
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
  -drive "if=pflash,format=raw,file=$VARS_B" \
  -drive "file=$DISK,format=raw,if=virtio" \
  -boot order=c -display none -serial "file:$SERIAL_B" -monitor none &
QEMU_B=$!
sleep "$WAIT"
kill "$QEMU_B" 2>/dev/null || true
wait "$QEMU_B" 2>/dev/null || true

FAIL=0
for want in 'live-media=absent(installed?)' 'user.session=yes(datum)' \
    'user.session.hyprland=yes' 'installer.fstab-root=uuid-ok' \
    'installer.fstab-efi=uuid-ok' 'installer.removable-bootloader=present' \
    'installer.live-user-removed=yes'; do
  key=${want%%=*}; val=${want#*=}
  if ! grep -q "DATUM_PROBE $key=$val" "$SERIAL_B"; then
    printf '%s\n' "test-install: MISSING/UNHEALTHY: $want" >&2
    FAIL=1
  fi
done
if test "$KEEP" = yes; then
  trap - EXIT INT TERM
  printf '%s\n' "test-install: keeping $DISK and $SERIAL_B" >&2
  cp "$DISK" ./emergence-test-disk.raw
  cp "$SERIAL_B" ./emergence-test-installed-serial.log
fi
rm -rf "$WORKDIR"
trap - EXIT INT TERM
test "$FAIL" -eq 0 && printf '%s\n' 'test-install: PASS: installed system boots with working desktop session.' >&2
exit "$FAIL"
