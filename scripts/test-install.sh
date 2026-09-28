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
SOCK="$WORKDIR/serial.sock"

# Phase A: live boot with a root shell, run the installer, power off.
VARS_A="$WORKDIR/ovmf-vars-a.fd"
cp -f "$(dirname "$OVMF_CODE")/OVMF_VARS.fd" "$VARS_A" 2>/dev/null || dd if=/dev/zero of="$VARS_A" bs=1M count=4 2>/dev/null
qemu-system-x86_64 -m 4096 -smp 4 -accel "$accel" -cpu "$cpu" \
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
  -drive "if=pflash,format=raw,file=$VARS_A" \
  -drive "file=$ISO,media=cdrom,if=virtio" \
  -drive "file=$DISK,format=raw,if=virtio" \
  -kernel "$WORKDIR/gentoo" -initrd "$WORKDIR/gentoo.igz" \
  -append "root=live:CDLABEL=DATUM_EMERGENCE_AMD64 rd.live.dir=/ rd.live.squashimg=image.squashfs cdroot console=ttyS0,115200 init=/bin/sh" \
  -display none -serial "unix:$SOCK,server,nowait" -monitor none &
QEMU_A=$!
TRANSCRIPT="$WORKDIR/install-serial.log"
python3 - "$SOCK" "$GUEST_DISK" "$GUEST_DISK_BYTES" "$TRANSCRIPT" <<'PYEOF'
import socket, sys, time
sock, disk, disk_bytes, transcript = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
tfile = open(transcript, "wb")
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(10)
for _ in range(60):
    try:
        s.connect(sock)
        break
    except (FileNotFoundError, ConnectionRefusedError):
        time.sleep(2)
else:
    print("FATAL: no serial");
    sys.exit(1)
s.settimeout(1.0)
buf = b""
def run(cmd, expect, timeout=900):
    global buf
    buf = b""
    tag = "TAG_%d" % int(time.time() * 1000 % 1000000)
    s.sendall(("\n" + cmd + "\necho %s:$?\n" % tag).encode())
    end = time.time() + timeout
    while time.time() < end:
        try:
            chunk = s.recv(65536)
        except socket.timeout:
            chunk = b""
        if chunk:
            buf += chunk
            tfile.write(chunk)
            tfile.flush()
        if (tag + ":").encode() in buf:
            break
        time.sleep(0.3)
    return expect.encode() in buf
# Cold boots (dracut live assembly, empty caches) can take minutes to reach
# init; poll patiently rather than failing fast.
synced = False
for _ in range(150):
    try:
        s.sendall(b"\necho SYNC_READY\n")
    except (BrokenPipeError, OSError):
        time.sleep(2)
        continue
    time.sleep(2)
    try:
        chunk = s.recv(65536)
    except socket.timeout:
        chunk = b""
    if chunk:
        buf += chunk
        tfile.write(chunk)
        tfile.flush()
    if b"SYNC_READY" in buf:
        synced = True
        break
if not synced:
    print("FATAL: no shell");
    sys.exit(1)
run("mount -t proc none /proc; mount -t sysfs none /sys; "
    "mount -t efivarfs none /sys/firmware/efi/efivars 2>/dev/null; "
    "test -b %s" % disk, "DISK_PRESENT", 60)
# Wrong-disk guard: the guest target must be exactly the expected size.
if not run("lsblk -bn -o SIZE -d %s" % disk, str(disk_bytes), 60):
    print("FATAL: guest disk size mismatch; refusing to install")
    sys.exit(1)
# Simulate the live firstboot lifecycle. This phase boots with init=/bin/sh
# (no systemd), so datum-firstboot-live never runs; create exactly what it
# would have created: a real local account, a home, and both live-user
# markers (persistent /etc one + runtime /run one). The installer must then
# remove that live-only identity from the target it copies.
if not run("EXTRA=\"\"; "
           "for g in wheel audio video render input plugdev cdrom; do "
           "getent group \"$g\" >/dev/null 2>&1 && EXTRA=\"$EXTRA $g\"; done; "
           "if test -n \"$EXTRA\"; then "
           "useradd -m -g users -G \"$(printf '%s' \"$EXTRA\" | tr ' ' ',')\" -s /bin/bash livetemp; "
           "else useradd -m -g users -s /bin/bash livetemp; fi; "
           "echo livetemp-canary > /home/livetemp/.live-canary; "
           "mkdir -p /etc/datum /run; "
           "echo livetemp > /etc/datum/live-user; echo livetemp > /run/datum-live-user; "
           "getent passwd livetemp && test -f /etc/datum/live-user && echo LIVE_USER_READY",
           "LIVE_USER_READY", 60):
    print("FATAL: live-user simulation failed")
    sys.exit(1)
ok = run("export EMERGENCE_INSTALL_PASSWORD=emergence-test-pass; "
         "datum-install --disk %s --user datum --hostname emergence-test "
         "--timezone UTC --yes" % disk, "installed Datum Emergence", 1200)
print("INSTALL %s" % ("SUCCESS" if ok else "FAILED"))
if not ok:
    sys.exit(1)
# Verify the target directly (still in the root shell, installer unmounted):
# the live-only account and its marker must be gone, the permanent user and
# its installed autologin must exist, and no live-firstboot files may linger.
ok = run("mkdir -p /mnt/verify; mount %s2 /mnt/verify && echo MOUNTED" % disk,
         "MOUNTED", 120)
if ok:
    ok = run("test ! -e /mnt/verify/etc/datum/live-user && "
             "! grep -q '^livetest:' /mnt/verify/etc/passwd && "
             "! grep -q '^livetest:' /mnt/verify/etc/shadow && "
             "! grep -q 'livetest' /mnt/verify/etc/group && "
             "test ! -e /mnt/verify/home/livetest && "
             "grep -q '^datum:' /mnt/verify/etc/passwd && "
             "grep -q 'initial_session' /mnt/verify/etc/greetd/config.toml && "
             "grep -q 'user = \"datum\"' /mnt/verify/etc/greetd/config.toml && "
             "test ! -e /mnt/verify/etc/systemd/system/datum-firstboot-live.service && "
             "test ! -e /mnt/verify/usr/local/bin/datum-firstboot-live && "
             "test ! -e /mnt/verify/etc/systemd/system/datum-firstboot.service && "
             "umount /mnt/verify && echo TARGET_VERIFY_OK",
             "TARGET_VERIFY_OK", 120)
print("TARGET-VERIFY %s" % ("SUCCESS" if ok else "FAILED"))
sys.exit(0 if ok else 1)
PYEOF
RC=$?
kill "$QEMU_A" 2>/dev/null || true
wait "$QEMU_A" 2>/dev/null || true
if test "$RC" -ne 0; then
  cp "$TRANSCRIPT" ./emergence-test-install-serial.log 2>/dev/null || true
  printf '%s\n' 'test-install: FAIL: installation did not complete; serial transcript kept at ./emergence-test-install-serial.log' >&2
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
