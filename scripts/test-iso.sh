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
WAIT=240
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
test -n "$SERIAL_LOG" || exit 2
: > "$SERIAL_LOG"
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
if grep -q 'DATUM_PROBE end' "$SERIAL_LOG" 2>/dev/null; then
  printf '%s\n' '--- probe summary ---' >&2
  grep 'DATUM_PROBE' "$SERIAL_LOG" >&2 || true
  FAIL=0
  for want in 'service.NetworkManager.service=active' 'service.greetd.service=active' 'user.session=yes(emergence)'; do
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
  exit "$FAIL"
fi
printf '%s\n' 'test-iso: FAIL: no probe markers in serial log; guest did not finish booting.' >&2
tail -n 20 "$SERIAL_LOG" >&2 || true
exit 1
