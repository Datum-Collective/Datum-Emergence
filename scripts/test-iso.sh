#!/bin/sh
# Boot the Emergence ISO in QEMU/KVM with UEFI when available.
#
# Interactive (default):
#   ./scripts/test-iso.sh dist/emergence-amd64.iso
#
# Automated boot check (used by ./build.sh test-ci):
#   ./scripts/test-iso.sh --ci /tmp/boot-serial.log dist/emergence-amd64.iso
# Boots headless with a serial console, waits for datum-boot-probe markers
# (or --wait seconds), quits QEMU, and exits 0 only if the probe reported a
# healthy boot. Pass --drive FILE to attach an extra virtio disk (installer
# tests) and --wait SECS to tune the timeout.
set -eu

MODE=interactive
SERIAL_LOG=""
WAIT=""
MEM=4096
SMP=4
EXTRA_DRIVE=""
OVMF_CODE=""
FIRSTBOOT_CREDS=""
DIRECT_BOOT=no

while test $# -gt 0; do
  case "$1" in
    --ci) MODE=ci; SERIAL_LOG=${2:?--ci needs a log path}; shift 2 ;;
    --firstboot) MODE=firstboot; FIRSTBOOT_CREDS=${2:?--firstboot needs USER:PASS}; shift 2 ;;
    --direct) DIRECT_BOOT=yes; shift ;;
    --wait) WAIT=${2:?--wait needs seconds}; shift 2 ;;
    --drive) EXTRA_DRIVE=${2:?--drive needs a disk image}; shift 2 ;;
    --mem) MEM=$2; shift 2 ;;
    --smp) SMP=$2; shift 2 ;;
    --ovmf) OVMF_CODE=$2; shift 2 ;;
    -h|--help)
      printf '%s\n' "usage: test-iso.sh [--ci LOG] [--firstboot USER:PASS] [--direct] [--wait SECS] [--drive DISK] [--mem MB] [--smp N] [--ovmf CODE.fd] ISO" >&2
      exit 2 ;;
    --*) printf '%s\n' "test-iso: unknown option $1" >&2; exit 2 ;;
    *) ISO=$1; shift ;;
  esac
done

test -n "${ISO:-}" || { printf '%s\n' 'test-iso: no ISO given' >&2; exit 2; }
test -s "$ISO" || { printf '%s\n' "test-iso: ISO not found: $ISO" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || { printf '%s\n' 'test-iso: qemu-system-x86_64 is required (app-emulation/qemu).' >&2; exit 1; }
# Mode-specific default waits: firstboot typing + login + desktop take longer.
if test -z "$WAIT"; then
  if test "$MODE" = firstboot; then WAIT=600; else WAIT=240; fi
fi

accel=tcg
cpu=max
if test -r /dev/kvm -a -w /dev/kvm; then accel=kvm; cpu=host; fi

# UEFI firmware: prefer an explicit --ovmf, else probe well-known paths.
if test -z "$OVMF_CODE"; then
  for candidate in /usr/share/edk2-ovmf/OVMF_CODE.fd /usr/share/edk2-ovmf/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
    if test -r "$candidate"; then OVMF_CODE=$candidate; break; fi
  done
fi

UEFI_ARGS=""
VARS_TMP=""
if test -n "$OVMF_CODE"; then
  # pflash (CODE + writable VARS copy) is the correct UEFI setup; -bios with
  # an OVMF CODE image alone has no NVRAM and misbehaves.
  VARS_TMP=$(mktemp /tmp/emergence-ovmf-vars-XXXXXX.fd)
  VARS_SRC=$(dirname "$OVMF_CODE")/OVMF_VARS.fd
  if test -r "$VARS_SRC"; then
    cp -f "$VARS_SRC" "$VARS_TMP"
  else
    # No VARS template: zeroed vars region; firmware still boots.
    dd if=/dev/zero of="$VARS_TMP" bs=1M count=4 2>/dev/null || true
  fi
  UEFI_ARGS="-drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE -drive if=pflash,format=raw,file=$VARS_TMP"
  FW_DESC="UEFI ($OVMF_CODE)"
else
  FW_DESC="BIOS (no OVMF found; install sys-firmware/edk2-ovmf for UEFI)"
fi

cleanup() { test -n "$VARS_TMP" -a -f "$VARS_TMP" && rm -f "$VARS_TMP"; }
trap 'cleanup' EXIT INT TERM

# The ISO is attached via virtio-blk, not IDE (-cdrom): the dist kernel does
# not enumerate QEMU's PIIX IDE CD in this configuration, while virtio works
# and matches modern VM practice. Real hardware uses SATA/USB (built in).
CDROM_DRIVE="file=$ISO,media=cdrom,if=virtio"
if test "$MODE" = interactive; then
  # shellcheck disable=SC2086
  set -- qemu-system-x86_64 -m "$MEM" -smp "$SMP" -accel "$accel" -cpu "$cpu" \
    -drive "$CDROM_DRIVE" -boot d $UEFI_ARGS
  if test -n "$EXTRA_DRIVE"; then set -- "$@" -drive "file=$EXTRA_DRIVE,format=raw,if=virtio"; fi
  printf '%s\n' "test-iso: booting with $accel and $FW_DESC." >&2
  exec "$@"
fi

# CI mode: headless, serial console to the log, quit after WAIT seconds.
# (Only --ci takes a caller-supplied log path; --firstboot uses a private one.)
test "$MODE" = ci && test -z "$SERIAL_LOG" && { printf '%s\n' 'test-iso: --ci needs a log path' >&2; exit 2; }
test -n "$SERIAL_LOG" && : > "$SERIAL_LOG"
# shellcheck disable=SC2086
set -- qemu-system-x86_64 -m "$MEM" -smp "$SMP" -accel "$accel" -cpu "$cpu" \
  -drive "$CDROM_DRIVE" -boot d $UEFI_ARGS \
  -display none -serial "file:$SERIAL_LOG" -monitor none
if test -n "$EXTRA_DRIVE"; then set -- "$@" -drive "file=$EXTRA_DRIVE,format=raw,if=virtio"; fi
printf '%s\n' "test-iso: CI boot with $accel and $FW_DESC (wait ${WAIT}s, log $SERIAL_LOG)." >&2
"$@" &
QEMU_PID=$!
sleep "$WAIT"
kill "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true
cleanup
trap - EXIT INT TERM

# Verdict from the in-image probe.
probe_verdict() {
  # $1 = expected session user (empty means: any user, live state file rules)
  expected=$1
  if grep -q 'DATUM_PROBE end' "$SERIAL_LOG" 2>/dev/null; then
    printf '%s\n' '--- probe summary ---' >&2
    grep 'DATUM_PROBE' "$SERIAL_LOG" >&2 || true
    FAIL=0
    wants="service.NetworkManager.service=active service.greetd.service=active"
    if test -n "$expected"; then
      wants="$wants user.session=yes($expected)"
    fi
    for want in $wants; do
      key=${want%%=*}; val=${want#*=}
      if ! grep -q "DATUM_PROBE $key=$val" "$SERIAL_LOG"; then
        printf '%s\n' "test-iso: MISSING/UNHEALTHY: $want" >&2
        FAIL=1
      fi
    done
    if grep -q 'DATUM_PROBE user.session.hyprland=yes' "$SERIAL_LOG"; then
      printf '%s\n' 'test-iso: Hyprland session reported active.' >&2
    else
      printf '%s\n' 'test-iso: WARNING: Hyprland not confirmed (software rendering may still be starting).' >&2
    fi
    return "$FAIL"
  fi
  printf '%s\n' 'test-iso: FAIL: no probe markers in serial log; guest did not finish booting.' >&2
  tail -n 20 "$SERIAL_LOG" >&2 || true
  return 1
}

if test "$MODE" = ci; then
  probe_verdict ""
  exit "$?"
fi

# Firstboot lifecycle test: type credentials into the live firstboot prompt
# and then into tuigreet, driving the guest's real TTY through the QEMU
# monitor. No test backdoors in the image: credentials live only in this
# invocation (test-only), typed like a human would type them.
if test "$MODE" = firstboot; then
  FB_USER=${FIRSTBOOT_CREDS%%:*}
  FB_PASS=${FIRSTBOOT_CREDS#*:}
  test -n "$FB_USER" -a -n "$FB_PASS" -a "$FB_USER" != "$FIRSTBOOT_CREDS" || { printf '%s\n' 'test-iso: --firstboot needs USER:PASS' >&2; exit 2; }
  case "$FB_USER$FB_PASS" in
    *[!a-z0-9]*)
      printf '%s\n' 'test-iso: firstboot test credentials must be [a-z0-9] (QEMU sendkey mapping)' >&2
      exit 2 ;;
  esac
  # Firstboot runs always use a private serial log (the --ci log path, if
  # any was given alongside, is left untouched). The log must survive until
  # after the verdict below; cleanup happens last.
  SERIAL_LOG=$(mktemp /tmp/emergence-firstboot-serial-XXXXXX.log)
  MON_SOCK=$(mktemp -u /tmp/emergence-firstboot-mon-XXXXXX.sock)
  TMPDIR_FB=$(mktemp -d /tmp/emergence-firstboot-XXXXXX)
  cleanup_fb() {
    rm -rf "$TMPDIR_FB"
    rm -f "$SERIAL_LOG" "$MON_SOCK"
    test -n "$VARS_TMP" -a -f "$VARS_TMP" && rm -f "$VARS_TMP"
  }
  trap 'cleanup_fb' EXIT INT TERM
  # shellcheck disable=SC2086
  set -- qemu-system-x86_64 -m "$MEM" -smp "$SMP" -accel "$accel" -cpu "$cpu"
  if test "$DIRECT_BOOT" = yes; then
    # Direct-kernel boot for full observability (serial console + journal).
    # GRUB itself is unchanged by firstboot work and covered separately.
    xorriso -indev "$ISO" -osirrox on \
      -extract /boot/gentoo "$TMPDIR_FB/gentoo" \
      -extract /boot/gentoo.igz "$TMPDIR_FB/gentoo.igz" >/dev/null 2>&1
    set -- "$@" -kernel "$TMPDIR_FB/gentoo" -initrd "$TMPDIR_FB/gentoo.igz" \
      -append "root=live:CDLABEL=DATUM_EMERGENCE_AMD64 rd.live.dir=/ rd.live.squashimg=image.squashfs cdroot console=ttyS0,115200 systemd.journald.forward_to_console=1"
  fi
  # shellcheck disable=SC2086
  set -- "$@" -drive "$CDROM_DRIVE" -boot d $UEFI_ARGS \
    -display none -serial "file:$SERIAL_LOG" -monitor "unix:$MON_SOCK,server,nowait"
  if test -n "$EXTRA_DRIVE"; then set -- "$@" -drive "file=$EXTRA_DRIVE,format=raw,if=virtio"; fi
  printf '%s\n' "test-iso: firstboot CI with $accel and $FW_DESC." >&2
  "$@" &
  QEMU_PID=$!
  python3 - "$MON_SOCK" "$SERIAL_LOG" "$FB_USER" "$FB_PASS" "$DIRECT_BOOT" <<'PYEOF'
import socket, sys, time
mon_sock, serial_log, user, pw, direct = sys.argv[1:6]
direct = (direct == "yes")
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
    # Drain monitor responses without blocking (see test-firstboot-checks.sh:
    # an unread monitor stalls QEMU command processing).
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
    # One HMP sendkey per call; keys like "ret" are single args.
    # Fire-and-forget delivery, but the socket is drained continuously (see
    # pump): queued keystrokes arrive in order; progress markers synchronize.
    try:
        m.sendall(("sendkey %s\r" % keys).encode())
    except (BrokenPipeError, OSError) as e:
        print("FATAL: monitor send failed: %s" % e)
        sys.exit(1)
    pump()

def stype(text, delay=0.4):
    for ch in text:
        if ch == '\n':
            sendkey("ret")
        elif ch == ' ':
            sendkey("spc")
        else:
            sendkey(ch)
        time.sleep(delay)
    sendkey("ret")
    time.sleep(1.0)

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

# Marker-driven interaction. firstboot writes progress markers (never
# secrets) to the serial console on every boot path, so each typed line is
# synchronized against guest-side evidence instead of blind sleeps. A lost
# keystroke therefore fails loudly at the step that lost it instead of
# silently mis-pairing every later line. Timeouts are generous for the GRUB
# path (firmware + GRUB + dracut live assembly under software rendering).
boot_timeout = 300 if direct else 900
if not wait_serial("Datum firstboot: starting user setup", boot_timeout):
    print("FATAL: firstboot never started")
    sys.exit(1)
# Phase 1: firstboot user creation. The accepted-username assertion is
# exact: a delivery flake mis-pairing a password into the username field
# would surface here as a missing marker.
stype(user)
if not wait_serial("username accepted: %s" % user, 300):
    print("FATAL: username not accepted")
    sys.exit(1)
stype(pw)
time.sleep(3)
stype(pw)
if not wait_serial("setup complete for %s" % user, 300):
    print("FATAL: setup did not complete")
    sys.exit(1)
if not wait_serial("Datum firstboot: starting greetd", 180):
    print("FATAL: greetd handoff never happened")
    sys.exit(1)
# Phase 2: tuigreet login with the created account.
time.sleep(25)
stype(user)
time.sleep(3)
stype(pw)
# Phase 3: let the desktop settle and the in-image probe report before the
# harness quits QEMU; killing the VM right after typing would destroy the
# very evidence the verdict needs.
if not wait_serial("DATUM_PROBE end", 600):
    print("FATAL: boot probe never finished")
    sys.exit(1)
print("TYPING DONE")
PYEOF
  RC=$?
  kill "$QEMU_PID" 2>/dev/null || true
  wait "$QEMU_PID" 2>/dev/null || true
  # Verdict BEFORE cleanup_fb: cleanup deletes the serial log. On failure
  # the log is kept for forensics (trap disarmed) while the bulky kernel
  # extract dir and the monitor socket are still removed.
  keep_log_on_failure() {
    rm -rf "$TMPDIR_FB" "$MON_SOCK"
    test -n "$VARS_TMP" -a -f "$VARS_TMP" && rm -f "$VARS_TMP"
    trap - EXIT INT TERM
  }
  if test "$RC" -ne 0; then
    printf '%s\n' "test-iso: FAIL: firstboot interaction driver failed; serial transcript kept at $SERIAL_LOG." >&2
    keep_log_on_failure
    exit 1
  fi
  # The test password must never appear in guest output (prompts mask it).
  # Username-accepted lines are excluded: they name the account, and a
  # delivery flake mis-pairing input there is caught by exact assertions.
  if grep -v 'username accepted:' "$SERIAL_LOG" 2>/dev/null | grep -q "$FB_PASS"; then
    printf '%s\n' 'test-iso: FAIL: password leaked into serial log.' >&2
    keep_log_on_failure
    exit 1
  fi
  probe_verdict "$FB_USER"
  VRC=$?
  cleanup_fb
  trap - EXIT INT TERM
  exit "$VRC"
fi
