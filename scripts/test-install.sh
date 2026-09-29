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
# Console note: the guest serial console is attached via TCP (telnet). The
# unix-socket serial backend delivered zero bytes from the guest on this
# host while the identical guest is verbose on file serial, and monitor
# sendkey input only reaches the VGA console, never a serial shell. TCP
# serial is bidirectional and proven here; the driver filters telnet
# negotiation bytes and logs everything it receives.
TELNET_PORT=4447
TRANSCRIPT="$PWD/emergence-install-serial-live.log"
rm -f "$TRANSCRIPT"
qemu-system-x86_64 -m 4096 -smp 4 -accel "$accel" -cpu "$cpu" \
  -drive "file=$ISO,media=cdrom,if=virtio" \
  -drive "file=$DISK,format=raw,if=virtio" \
  -kernel "$WORKDIR/gentoo" -initrd "$WORKDIR/gentoo.igz" \
  -append "root=live:CDLABEL=DATUM_EMERGENCE_AMD64 rd.live.dir=/ rd.live.squashimg=image.squashfs cdroot console=ttyS0,115200 init=/bin/sh" \
  -display none -serial "telnet:127.0.0.1:$TELNET_PORT,server,nowait" -monitor none &
QEMU_A=$!
python3 - "$TELNET_PORT" "$TRANSCRIPT" "$GUEST_DISK" "$GUEST_DISK_BYTES" <<'PYEOF'
import socket, sys, time
telnet_port, transcript, disk, disk_bytes = int(sys.argv[1]), sys.argv[2], sys.argv[3], int(sys.argv[4])
tfile = open(transcript, "wb", buffering=0)
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(5)
for _ in range(60):
    try:
        s.connect(("127.0.0.1", telnet_port))
        break
    except OSError:
        time.sleep(2)
else:
    print("FATAL: no telnet serial (QEMU never listened)")
    sys.exit(1)
s.settimeout(1.0)
def filtered(data):
    # Strip telnet negotiation (IAC DO/WILL xxx), answering DO->WONT and
    # WILL->DONT so the server stops asking.
    out = bytearray()
    i = 0
    while i < len(data):
        if data[i] == 0xFF and i + 2 < len(data):
            cmd, opt = data[i + 1], data[i + 2]
            if cmd in (0xFD, 0xFB):
                try:
                    s.sendall(bytes((0xFF, 0xFC if cmd == 0xFD else 0xFE, opt)))
                except OSError:
                    pass
            i += 3
        else:
            out.append(data[i])
            i += 1
    return bytes(out)
buf = b""
def run(cmd, expect, timeout=900):
    global buf
    buf = b""
    tag = "TAG_%d" % int(time.time() * 1000 % 1000000)
    want = (tag + ":").encode()
    try:
        s.sendall(("\n" + cmd + "\necho %s:$?\n" % tag).encode())
    except (BrokenPipeError, OSError) as e:
        print("FATAL: serial send failed: %s" % e)
        sys.exit(1)
    end = time.time() + timeout
    while time.time() < end:
        try:
            chunk = s.recv(65536)
        except socket.timeout:
            chunk = b""
        if chunk:
            clean = filtered(chunk)
            buf += clean
            tfile.write(clean)
        # The guest tty echoes our input, so the tag first appears in the
        # echo of the marker line itself (within milliseconds); only the
        # SECOND occurrence is the marker really executing after the command
        # finished. Matching once returns slow commands (install, copy) on
        # their own echo with the expected output still missing.
        if buf.count(want) >= 2:
            break
        time.sleep(0.3)
    return expect.encode() in buf
# The boot logs may predate our connection (telnet drops pre-connect
# output), so prove bidirectionality with a fresh newline: the shell
# echoes it and prints a new prompt.
for _ in range(150):
    try:
        s.sendall(b"\n")
    except (BrokenPipeError, OSError):
        time.sleep(2)
        continue
    time.sleep(2)
    try:
        chunk = s.recv(65536)
    except socket.timeout:
        chunk = b""
    if chunk:
        clean = filtered(chunk)
        buf += clean
        tfile.write(clean)
    if b"sh-5.3#" in buf:
        break
else:
    print("FATAL: no shell")
    sys.exit(1)
print("guest shell is bidirectional")
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
           "LIVE_USER_READY", 120):
    print("FATAL: live-user simulation failed")
    sys.exit(1)
ok = run("export EMERGENCE_INSTALL_PASSWORD=emergence-test-pass; "
         "datum-install --disk %s --user datum --hostname emergence-test "
         "--timezone UTC --yes" % disk, "installed Datum Emergence", 1500)
print("INSTALL %s" % ("SUCCESS" if ok else "FAILED"))
sys.exit(0 if ok else 1)
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
# A compositor process without a Wayland socket is the exact "starts then
# immediately exits / never really up" regression: require the socket the
# probe records alongside user.session.hyprland=yes.
if grep -q 'DATUM_PROBE user.session.wayland-socket=no' "$SERIAL_B"; then
  printf '%s\n' 'test-install: MISSING/UNHEALTHY: user.session.wayland-socket (Hyprland up but no socket)' >&2
  FAIL=1
fi
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
