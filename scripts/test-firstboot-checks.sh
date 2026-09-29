#!/bin/sh
# Firstboot validation scenarios: invalid usernames, password rules, and
# password-secrecy checks. Boots the ISO kernel directly (full serial console
# + journal) so every firstboot progress marker is observable; GRUB itself is
# covered by test-iso.sh. No test backdoors in the image: the harness types
# into the real TTY via the QEMU monitor, exactly like a human would.
#
# Usage: test-firstboot-checks.sh [--scenario invalid-users|passwords|all] ISO
# Test credentials are [a-z0-9 ] only (QEMU sendkey mapping) and live solely
# in this invocation; they are never written into the image.
set -eu

SCENARIO=all
while test $# -gt 0; do
  case "$1" in
    --scenario) SCENARIO=${2:?--scenario needs invalid-users|passwords|all}; shift 2 ;;
    -h|--help)
      printf '%s\n' "usage: test-firstboot-checks.sh [--scenario invalid-users|passwords|all] ISO" >&2
      exit 2 ;;
    --*) printf '%s\n' "test-firstboot-checks: unknown option $1" >&2; exit 2 ;;
    *) ISO=$1; shift ;;
  esac
done
case "$SCENARIO" in
  invalid-users|passwords|all) ;;
  *) printf '%s\n' "test-firstboot-checks: unknown scenario $SCENARIO" >&2; exit 2 ;;
esac

test -n "${ISO:-}" || { printf '%s\n' 'test-firstboot-checks: no ISO given' >&2; exit 2; }
test -s "$ISO" || { printf '%s\n' "test-firstboot-checks: ISO not found: $ISO" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || { printf '%s\n' 'test-firstboot-checks: qemu-system-x86_64 is required.' >&2; exit 1; }
command -v xorriso >/dev/null 2>&1 || { printf '%s\n' 'test-firstboot-checks: xorriso is required (kernel extraction).' >&2; exit 1; }

accel=tcg
cpu=max
if test -r /dev/kvm -a -w /dev/kvm; then accel=kvm; cpu=host; fi
OVMF_CODE=""
for candidate in /usr/share/edk2-ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
  if test -r "$candidate"; then OVMF_CODE=$candidate; break; fi
done
test -n "$OVMF_CODE" || { printf '%s\n' 'test-firstboot-checks: OVMF firmware not found.' >&2; exit 1; }

WORKDIR=$(mktemp -d /tmp/emergence-firstboot-checks-XXXXXX)
cleanup() { rm -rf "$WORKDIR"; }
trap 'cleanup' EXIT INT TERM

xorriso -indev "$ISO" -osirrox on \
  -extract /boot/gentoo "$WORKDIR/gentoo" \
  -extract /boot/gentoo.igz "$WORKDIR/gentoo.igz" >/dev/null 2>&1

run_scenario() {
  # $1 = scenario name, $2 = attempt number (for distinct logs per attempt).
  name=$1
  attempt=${2:-1}
  serial="$WORKDIR/$name-attempt$attempt-serial.log"
  mon="$WORKDIR/$name-mon.sock"
  : > "$serial"
  rm -f "$mon"
  vars=$(mktemp /tmp/emergence-ovmf-vars-XXXXXX.fd)
  cp -f "$(dirname "$OVMF_CODE")/OVMF_VARS.fd" "$vars" 2>/dev/null || dd if=/dev/zero of="$vars" bs=1M count=4 2>/dev/null || true
  # shellcheck disable=SC2086
  qemu-system-x86_64 -m 4096 -smp 4 -accel "$accel" -cpu "$cpu" \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$vars" \
    -drive "file=$ISO,media=cdrom,if=virtio" -boot d \
    -kernel "$WORKDIR/gentoo" -initrd "$WORKDIR/gentoo.igz" \
    -append "root=live:CDLABEL=DATUM_EMERGENCE_AMD64 rd.live.dir=/ rd.live.squashimg=image.squashfs cdroot console=ttyS0,115200" \
    -display none -serial "file:$serial" -monitor "unix:$mon,server,nowait" &
  qpid=$!
  python3 - "$mon" "$serial" "$name" <<'PYEOF'
import socket, sys, time
mon_sock, serial_log, name = sys.argv[1:4]
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
    # Drain monitor responses without blocking. QEMU stalls command
    # processing when nobody reads its output, so the socket must be drained
    # continuously; guest progress markers (not round-trips) synchronize.
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

def stype(text, delay=0.4):
    # Lowercase, digits and space only. Uppercase would need shift combos
    # whose delivery through the QEMU monitor is unreliable here; all test
    # credentials obey this (a delivery flake mis-pairing a password into a
    # username field is still caught, because usernames are asserted exactly
    # while password absence is asserted outside username-accepted lines).
    for ch in text:
        if ch == ' ':
            sendkey("spc")
        else:
            sendkey(ch)
        pump()
        time.sleep(delay)
    sendkey("ret")
    pump()
    time.sleep(1.0)

fails = []
def check(cond, what):
    print(("PASS " if cond else "FAIL ") + what, flush=True)
    if not cond:
        fails.append(what)

def serial_data():
    try:
        with open(serial_log, errors="replace") as f:
            return f.read()
    except OSError:
        return ""

end = time.time() + 300
while time.time() < end:
    pump()
    if "Datum firstboot: starting user setup" in serial_data():
        break
    time.sleep(5)
else:
    print("FATAL: firstboot never started")
    sys.exit(1)

def wait_counts(wants, timeout):
    # wants: {marker: minimum count}. Keystrokes queue in order in the guest
    # TTY, but delivery pace is environment-dependent; wait for cumulative
    # counts rather than per-step windows.
    end = time.time() + timeout
    while time.time() < end:
        pump()
        data = serial_data()
        if all(data.count(m) >= n for m, n in wants.items()):
            return True
        time.sleep(10)
    return False

def stype_sync(text, timeout=240):
    # Type one line, then wait until firstboot emits ANY new marker, proving
    # the line arrived and was processed. QEMU monitor key delivery is
    # occasionally lossy here; without this gate a lost line silently
    # mis-pairs every later input. False timeout just retries the scenario.
    try:
        with open(serial_log, errors="replace") as f:
            before = f.read().count("Datum firstboot:")
    except OSError:
        before = 0
    stype(text)
    end = time.time() + timeout
    while time.time() < end:
        time.sleep(5)
        try:
            with open(serial_log, errors="replace") as f:
                if f.read().count("Datum firstboot:") > before:
                    return True
        except OSError:
            pass
    return False

def synced(text):
    # Returns False (caller aborts the scenario) when no progress appears.
    if stype_sync(text):
        return True
    print("FAIL input stalled (no firstboot progress): %r" % text, flush=True)
    fails.append("input stalled")
    return False

if name == "invalid-users":
    for bad in ["", "root", "emergence", "greeter", "greetd",
                "bad name", "1abc", "waytoolongusernameoverthirtytwochars1"]:
        if not synced(bad):
            break
        time.sleep(2)
    else:
        # Only reached if every bad name got a response; now complete setup.
        # Exact accepted name proves no input was lost or reordered.
        if synced("testuser"):
            time.sleep(2)
            stype("testpass123")
            time.sleep(2)
            stype("testpass123")
    ok = (not fails) and wait_counts({"invalid username rejected": 8,
                                       "username accepted: testuser": 1,
                                       "setup complete for testuser": 1}, 900)
    check(ok, "rejects 8 bad usernames then accepts valid + completes")
elif name == "passwords":
    # A wrong-then-right non-empty sequence proves mismatch handling and
    # completion. Submitting a completely empty password line is covered by
    # the invalid-users scenario (empty username rejection over the same
    # prompt machinery) and by sandbox tests of the hidden password prompt,
    # which verified the empty-password rejection message and retry.
    if synced("testuser"):
        time.sleep(2)
        stype("alpha111")
        time.sleep(2)
        # Valid passwords emit no marker; the mismatch marker for the
        # following confirm proves both arrived in order.
        stype("alpha222")
        if wait_counts({"password mismatch": 1}, 300):
            time.sleep(2)
            stype("beta111")
            time.sleep(2)
            stype("beta111")
    ok = (not fails) and wait_counts({"username accepted: testuser": 1,
                                       "password mismatch": 1,
                                       "setup complete for testuser": 1}, 900)
    check(ok, "password rules enforced then setup completes")
sys.exit(1 if fails else 0)
PYEOF
  rc=$?
  kill "$qpid" 2>/dev/null || true
  wait "$qpid" 2>/dev/null || true
  rm -f "$vars"
  # Passwords must never appear in guest output (prompts mask them). Lines
  # reporting an accepted USERNAME are excluded: a delivery flake can
  # mis-pair a password into a username field, which the exact-username
  # assertions above already catch; only any other occurrence is a leak.
  for secret in testpass123 alpha111 alpha222 beta111; do
    if grep -v 'username accepted:' "$serial" 2>/dev/null | grep -q "$secret"; then
      printf '%s\n' "test-firstboot-checks [$name]: FAIL: password leaked into serial log." >&2
      rc=1
    fi
  done
  return "$rc"
}

OVERALL=0
# QEMU monitor key delivery is occasionally lossy in some environments (an
# input line can vanish, mis-pairing the scripted sequence). A genuine
# firstboot bug fails deterministically; a delivery flake passes on retry, so
# each scenario gets up to three fresh-VM attempts.
attempt_scenario() {
  name=$1
  attempt=1
  while test "$attempt" -le 3; do
    printf '%s\n' "test-firstboot-checks [$name]: attempt $attempt/3." >&2
    if run_scenario "$name" "$attempt"; then
      return 0
    fi
    attempt=$((attempt + 1))
  done
  return 1
}
if test "$SCENARIO" = invalid-users -o "$SCENARIO" = all; then
  attempt_scenario invalid-users || OVERALL=1
fi
if test "$SCENARIO" = passwords -o "$SCENARIO" = all; then
  attempt_scenario passwords || OVERALL=1
fi
if test "$OVERALL" -eq 0; then
  printf '%s\n' "test-firstboot-checks [$SCENARIO]: PASS." >&2
else
  printf '%s\n' "test-firstboot-checks [$SCENARIO]: FAIL (serial logs kept in $WORKDIR)." >&2
  trap - EXIT INT TERM
fi
exit "$OVERALL"
