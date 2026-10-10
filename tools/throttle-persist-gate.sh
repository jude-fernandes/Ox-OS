#!/bin/sh
# Throttle-persistence gate (chunk 56, hardened in chunk 58): the
# lockout backoff must SURVIVE a power cycle — an attacker cannot
# clear it by rebooting.
#   Boot 1 (fresh volume): 4 wrong PINs, journals pin-verify-denied with
#     escalating throttle-next-ms (1s,2s,4s,8s); kill QEMU inside the
#     16s armed window.
#   Boot 2 (SAME data volume): the 5th wrong PIN must journal
#     throttle-next-ms=16000 — proving consecutive=4 was RESTORED from
#     the HMAC-tagged persisted record (a fresh state would arm 1s).
#     Then the owner unlocks (success-after-failures resets + persists).
# Chunk 58 hardening: every PIN injection is COUNT-VERIFIED — the gate
# waits for a NEW denial/unlock line, not merely the pattern existing
# (the old wait matched PIN 1's line forever and silently swallowed
# stolen taps). Retries exist because in-guest selftests (wifi join,
# Hello relaunch — chunk-57 420s grace) can open windows over the
# lockscreen mid-drill and eat a pad tap; tracked finding, not noise.
# usage: throttle-persist-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="${2:-/nix/store/qf3508h6zl2yq3vx6j236nq3r8dns4d9-linux-aarch64-unknown-linux-gnu-6.18.48/Image}"; TMO="${3:-2400}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$OXDIR/tools/gate-lib.sh"   # chunk-54 guest-time waits
OUT=/tmp/ox-tpgate
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-tp] %s\n' "$*"; }
fail() { printf '[ox-tp] FAIL: %s\n' "$*" >&2; exit 1; }

qmp_pin() {
    python3 - "$1" <<'PYEOF'
import json, socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.connect("/tmp/ox-qmp")
f = s.makefile("rw")
f.readline()
def send(c):
    f.write(json.dumps(c) + "\n"); f.flush()
    return json.loads(f.readline())
send({"execute": "qmp_capabilities"})
send({"execute": "system_wakeup"})
time.sleep(2.0)
def ev(events):
    r = send({"execute": "input-send-event", "arguments": {"events": events}})
    assert "error" not in r, r
    time.sleep(0.15)
def tap(sx, sy):
    move1 = [{"type": "abs", "data": {"axis": "x", "value": int(sx * 32767 / 1280)}},
             {"type": "abs", "data": {"axis": "y", "value": int(sy * 32767 / 800)}}]
    ev(move1)
    time.sleep(0.4)
    ev(move1)
    ev([{"type": "btn", "data": {"down": True, "button": "left"}}])
    ev([{"type": "btn", "data": {"down": False, "button": "left"}}])
keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "C", "0", "OK"]
rects = [(353 + (i % 3) * 102, 420 + (i // 3) * 68, 90, 56) for i in range(12)]
for ch in sys.argv[1]:
    i = keys.index(ch)
    x, y, w, h = rects[i]
    tap(x + w / 2, y + h / 2)
    time.sleep(1.0)
i = keys.index("OK")
x, y, w, h = rects[i]
tap(x + w / 2, y + h / 2)
print("[ox-tp] PIN digits + OK injected")
PYEOF
}

wait_ms() {
    _pat="$1"; _max="$2"; _label="$3"
    k=0
    while [ $k -lt "$_max" ]; do
        grep -aq "$_pat" "$LOG" 2>/dev/null && return 0
        if [ $((k % 10)) -eq 5 ]; then
            python3 - <<'PYW' 2>/dev/null || true
import socket
try:
    s = socket.socket(socket.AF_UNIX)
    s.connect("/tmp/ox-qmon")
    s.settimeout(2)
    s.recv(4096)
    s.sendall(b"system_wakeup" + chr(10).encode())
except Exception:
    pass
PYW
        fi
        sleep 2; k=$((k + 1))
    done
    fail "$_label (pattern not observed: $_pat)"
}

# grep -c always prints exactly one line (0 included) — never append a
# fallback zero here: "0\n0" makes every [ -gt ] comparison fail.
pcount() {
    _PC=$(grep -ac "$1" "$LOG" 2>/dev/null || true)
    : ${_PC:=0}
}

# The backoff caps at 60s: once 65s pass with no NEW denial, the pad
# can evaluate a fresh attempt (the owner unlock must not be eaten by
# the window its own retries armed).
throttle_expired() {
    pcount "pin-verify-denied"; _a=$_PC
    i=0
    while [ $i -lt 6 ]; do
        sleep 65
        pcount "pin-verify-denied"
        [ "$_PC" = "$_a" ] && return 0
        _a=$_PC
        i=$((i + 1))
    done
}

# Inject PIN until the pattern gains a NEW line (chunk 58): stolen or
# throttled taps are retried, and every retry is a fresh injection —
# the milestone line must come from THIS pad entry, not an earlier one.
pin_step() {
    _pin="$1"; _pat="$2"; _label="$3"
    pcount "$_pat"; _before=$_PC
    _try=0
    while :; do
        qmp_pin "$_pin"
        _k=0
        while [ $_k -lt 120 ]; do
            pcount "$_pat"
            [ "$_PC" -gt "$_before" ] && return 0
            sleep 2; _k=$((_k + 1))
        done
        _try=$((_try + 1))
        [ $_try -ge 3 ] && fail "$_label (pattern never advanced: $_pat)"
        say "$_label: tap possibly stolen, retry $_try"
        sleep 20
    done
}

boot_and_settle() {
    (OX_KERNEL_EXTRA=" ox.pm_drill=off" OX_GFX=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
        "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)
    i=0
    while [ $i -lt 150 ]; do
        grep -aq "name=shell-locked" "$LOG" 2>/dev/null && break
        sleep 2; i=$((i + 1))
    done
    grep -aq "name=lockd-ready" "$LOG" || fail "no lockd-ready milestone"
    k=0
    while [ $k -lt 300 ]; do
        grep -aq "name=resourced-tier-ok" "$LOG" 2>/dev/null && break
        grep -aq "name=resourced-tier-failed" "$LOG" 2>/dev/null && break
        sleep 2; k=$((k + 1))
    done
    say "boot settled (lockd + resourced ready)"
}

# ---- BOOT 1: four wrong PINs, then hard power-cut inside the window
LOG="$OUT/serial-tp1.log"
boot_and_settle
# chunk 58: the in-guest scrub selftest must have sent a decoy secret
# over the real socket and seen lockd zero it (journals name=ipc-scrub)
wait_ms "name=ipc-scrub" 150 "ipc scrub selftest never journaled a clean result"
say "IPC scrub proven in-guest (wire decoy reads back all-zero)"
N=0
while [ $N -lt 4 ]; do
    pin_step 0000 "pin-verify-denied" "wrong PIN $((N + 1))"
    N=$((N + 1))
    say "wrong PIN $N evaluated (denial journalled)"
    # wait out the armed backoff before the next attempt
    sleep $((N * 2 + 2))
done
grep -aq "throttle-next-ms=8000" "$LOG" || fail "expected the 4th failure to arm an 8s window"
say "escalation curve observed (1s,2s,4s,8s)"
say "BOOT 1: power-cutting inside the 16s armed window"
pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 3

# ---- BOOT 2: same data volume; the 5th wrong PIN must arm 16s
LOG="$OUT/serial-tp2.log"
boot_and_settle
pin_step 0000 "pin-verify-denied" "5th wrong PIN"
grep -aq "throttle-next-ms=16000\|throttle-next-ms=32000" "$LOG" \
    || fail "the 5th wrong PIN did not arm >=16s: the persisted counter was lost"
say "PERSISTENCE PROVEN: 5th failure armed 16s (consecutive=4 survived the reboot)"

# owner unlock: the counter (>0) must surface success-after-failures
sleep 35
say "waiting out the armed window before the owner attempt"
throttle_expired
pin_step 1234 "name=shell-unlocked" "owner unlock"
wait_ms "name=pin-verify-success-after-failures" 20 "throttle reset journal missing"
say "owner unlocked; reset persisted (consecutive back to 0)"
say "ALL GREEN — lockout backoff survives a power cycle: 4 failures before the cut, 16s window armed after it, owner restored"
echo "THROTTLE-PERSIST GATE ALL GREEN"
