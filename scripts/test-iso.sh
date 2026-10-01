#!/bin/sh
# Boot the Emergence ISO in QEMU/KVM with UEFI when available.
#
# Interactive (default):
#   ./scripts/test-iso.sh dist/emergence-amd64.iso
#
# Automated boot check (used by ./build.sh test-ci):
#   ./scripts/test-iso.sh --ci /tmp/boot-serial.log dist/emergence-amd64.iso
# Boots headless with a serial console, waits for the installer menu marker
# and datum-boot-probe completion (or --wait seconds), quits QEMU, and exits
# 0 only if the probe reported a healthy installer boot: installer service
# active, live marker present, no login session (the live ISO never logs
# anyone in). Pass --drive FILE to attach an extra virtio disk and --wait
# SECS to tune the timeout.
set -eu

MODE=interactive
SERIAL_LOG=""
WAIT=600
MEM=4096
SMP=4
EXTRA_DRIVE=""
OVMF_CODE=""

while test $# -gt 0; do
  case "$1" in
    --ci) MODE=ci; SERIAL_LOG=${2:?--ci needs a log path}; shift 2 ;;
    --wait) WAIT=${2:?--wait needs seconds}; shift 2 ;;
    --drive) EXTRA_DRIVE=${2:?--drive needs a disk image}; shift 2 ;;
    --mem) MEM=$2; shift 2 ;;
    --smp) SMP=$2; shift 2 ;;
    --ovmf) OVMF_CODE=$2; shift 2 ;;
    -h|--help)
      printf '%s\n' "usage: test-iso.sh [--ci LOG] [--wait SECS] [--drive DISK] [--mem MB] [--smp N] [--ovmf CODE.fd] ISO" >&2
      exit 2 ;;
    --*) printf '%s\n' "test-iso: unknown option $1" >&2; exit 2 ;;
    *) ISO=$1; shift ;;
  esac
done

test -n "${ISO:-}" || { printf '%s\n' 'test-iso: no ISO given' >&2; exit 2; }
test -s "$ISO" || { printf '%s\n' "test-iso: ISO not found: $ISO" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || { printf '%s\n' 'test-iso: qemu-system-x86_64 is required (app-emulation/qemu).' >&2; exit 1; }

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
test -n "$SERIAL_LOG" || { printf '%s\n' 'test-iso: --ci needs a log path' >&2; exit 2; }
: > "$SERIAL_LOG"
# shellcheck disable=SC2086
set -- qemu-system-x86_64 -m "$MEM" -smp "$SMP" -accel "$accel" -cpu "$cpu" \
  -drive "$CDROM_DRIVE" -boot d $UEFI_ARGS \
  -display none -serial "file:$SERIAL_LOG" -monitor none
if test -n "$EXTRA_DRIVE"; then set -- "$@" -drive "file=$EXTRA_DRIVE,format=raw,if=virtio"; fi
printf '%s\n' "test-iso: CI boot with $accel and $FW_DESC (wait up to ${WAIT}s, log $SERIAL_LOG)." >&2
"$@" &
QEMU_PID=$!
# State markers, not a blind sleep: quit as soon as the guest proves a
# healthy boot (probe completion + installer menu), with WAIT as the cap.
# (A fixed sleep wastes the whole window on every passing run and leaves
# teardown to the last second.)
end=$(($(date +%s) + WAIT))
while test "$(date +%s)" -lt "$end"; do
  if grep -q 'DATUM_PROBE end' "$SERIAL_LOG" 2>/dev/null \
    && grep -q 'Datum installer: menu' "$SERIAL_LOG" 2>/dev/null; then
    break
  fi
  sleep 10
done
kill "$QEMU_PID" 2>/dev/null || true
for _ in $(seq 1 30); do
  kill -0 "$QEMU_PID" 2>/dev/null || break
  sleep 2
done
kill -9 "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true
cleanup
trap - EXIT INT TERM

# Verdict from the in-image probe and installer markers.
if grep -q 'DATUM_PROBE end' "$SERIAL_LOG" 2>/dev/null; then
  printf '%s\n' '--- probe summary ---' >&2
  grep 'DATUM_PROBE' "$SERIAL_LOG" >&2 || true
  FAIL=0
  for want in 'live-media=present' \
      'service.NetworkManager.service=active' \
      'service.datum-installer.service=active' \
      'installer.live-marker=present' \
      'user.session=no(live-installer)'; do
    key=${want%%=*}; val=${want#*=}
    if ! grep -q "DATUM_PROBE $key=$val" "$SERIAL_LOG"; then
      printf '%s\n' "test-iso: MISSING/UNHEALTHY: $want" >&2
      FAIL=1
    fi
  done
  # The installer menu must have painted (its marker proves the TUI reached
  # the interactive state with a clean VT handoff).
  if grep -q 'Datum installer: menu' "$SERIAL_LOG" 2>/dev/null; then
    printf '%s\n' 'test-iso: installer menu reached.' >&2
  else
    printf '%s\n' 'test-iso: MISSING/UNHEALTHY: installer menu marker' >&2
    FAIL=1
  fi
  # No greeter and no graphical session may exist on live media: the ISO is
  # an installer, not a desktop.
  if grep -q 'DATUM_PROBE user.session=yes' "$SERIAL_LOG" 2>/dev/null; then
    printf '%s\n' 'test-iso: UNHEALTHY: unexpected login session on live media' >&2
    FAIL=1
  fi
  test "$FAIL" -eq 0 && printf '%s\n' 'test-iso: PASS: live installer boot is healthy.' >&2
  exit "$FAIL"
fi
printf '%s\n' 'test-iso: FAIL: no probe markers in serial log; guest did not finish booting.' >&2
tail -n 20 "$SERIAL_LOG" >&2 || true
exit 1
