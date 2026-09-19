#!/bin/sh
set -eu
iso=${1:?usage: test-iso.sh path/to/emergence-amd64.iso}
test -s "$iso" || { printf '%s\n' "ISO not found: $iso" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || { printf '%s\n' 'qemu-system-x86_64 is required (install app-emulation/qemu[...]).' >&2; exit 1; }
accel=tcg
cpu=max
if test -r /dev/kvm; then accel=kvm; cpu=host; fi
firmware=
for candidate in /usr/share/edk2-ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
  if test -r "$candidate"; then firmware=$candidate; break; fi
done
set -- qemu-system-x86_64 -m 4096 -smp 4 -accel "$accel" -cpu "$cpu" -cdrom "$iso" -boot d
if test -n "$firmware"; then set -- "$@" -bios "$firmware"; fi
printf '%s\n' "Booting with $accel${firmware:+ and UEFI firmware $firmware}."
exec "$@"
