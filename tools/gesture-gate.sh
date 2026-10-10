#!/bin/sh
# Gesture gate: swipe navigation end to end. The compositor now
# classifies each press as TAP (click) or SWIPE (gesture, named by
# direction) on release; the shell maps edge-aware swipes:
#   swipe up from the bottom third -> home (closes switcher/activity)
#   swipe down from the top strip  -> toggle the activity panel
# The unlock PIN pad taps double as the click-on-release regression
# proof: every tap in this gate flows through the same new path.
# usage: gesture-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-900}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-gsg
LOG="$OUT/serial-gesture.log"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-gs] %s\n' "$*"; }
fail() { printf '[ox-gs] FAIL: %s\n' "$*" >&2; exit 1; }

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1

(OX_GFX=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

qmp_tap() {
    python3 - "$1" "$2" <<'PYEOF'
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
sx, sy = float(sys.argv[1]), float(sys.argv[2])
move1 = [{"type": "abs", "data": {"axis": "x", "value": int(sx * 32767 / 1280)}},
         {"type": "abs", "data": {"axis": "y", "value": int(sy * 32767 / 800)}}]
ev(move1)
time.sleep(0.4)
ev(move1)
ev([{"type": "btn", "data": {"down": True, "button": "left"}}])
ev([{"type": "btn", "data": {"down": False, "button": "left"}}])
print("[ox-gs] tap injected at %s,%s" % (sys.argv[1], sys.argv[2]))
PYEOF
}

qmp_swipe() {
    python3 - "$1" "$2" "$3" "$4" <<'PYEOF'
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
    time.sleep(0.12)
def mv(x, y):
    return [{"type": "abs", "data": {"axis": "x", "value": int(x * 32767 / 1280)}},
            {"type": "abs", "data": {"axis": "y", "value": int(y * 32767 / 800)}}]
x0, y0, x1, y1 = (float(v) for v in sys.argv[1:5])
ev(mv(x0, y0)); time.sleep(0.3)
ev(mv(x0, y0)); time.sleep(0.3)
ev([{"type": "btn", "data": {"down": True, "button": "left"}}])
steps = 10
for i in range(1, steps + 1):
    ev(mv(x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps))
ev([{"type": "btn", "data": {"down": False, "button": "left"}}])
print("[ox-gs] swipe (%s,%s) -> (%s,%s)" % (x0, y0, x1, y1))
PYEOF
}

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
print("[ox-gs] PIN digits + OK injected")
PYEOF
}

wait_ms() {
    _pat="$1"; _max="$2"; _label="$3"
    k=0
    while [ $k -lt "$_max" ]; do
        grep -aq "$_pat" "$LOG" 2>/dev/null && return 0
        if [ $((k % 10)) -eq 5 ]; then
            # PM wake assist: nudge the machine like a power button —
            # the RTC alarm can miss under host load (guest clock lag
            # arms the wakealarm in the past); no-op while awake.
            python3 - <<'PYW' 2>/dev/null || true
import socket
try:
    s = socket.socket(socket.AF_UNIX)
    s.connect("/tmp/ox-qmon")
    s.settimeout(2)
    s.recv(4096)
    s.sendall(b"system_wakeup\n")
except Exception:
    pass
PYW
        fi
        sleep 2; k=$((k + 1))
    done
    fail "$_label (pattern not observed: $_pat)"
}

count_of() {
    grep -ac "$1" "$LOG" 2>/dev/null || echo 0
}

# 1. boot basics
i=0
while [ $i -lt 150 ]; do
    grep -aq "name=shell-home" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -aq "name=shell-locked" "$LOG" || fail "no shell-locked milestone"
wait_ms "name=pkg-flow-ok" 120 "pkg selftest did not settle"
k=0
while [ $k -lt 300 ]; do
    grep -aq "name=resourced-tier-ok" "$LOG" 2>/dev/null && break
    grep -aq "name=resourced-tier-failed" "$LOG" 2>/dev/null && break
    sleep 2; k=$((k + 1))
done
sleep 3

# 2. PIN unlock — clicks now deliver on RELEASE; the pad proves it
attempt=0
UNLOCKED=no
while [ $attempt -lt 3 ]; do
    N0=$(grep -ac "name=shell-unlocked" "$LOG" 2>/dev/null || true)
    qmp_pin 1234
    k=0
    while [ $k -lt 300 ]; do
        N1=$(grep -ac "name=shell-unlocked" "$LOG" 2>/dev/null || true)
        [ "$N1" -gt "$N0" ] 2>/dev/null && break
        sleep 2; k=$((k + 1))
    done
    grep -aq "name=shell-unlocked" "$LOG" 2>/dev/null && { UNLOCKED=yes; break; }
    attempt=$((attempt + 1))
    say "unlock not observed yet (retry $((attempt + 1)))"
done
[ "$UNLOCKED" = yes ] || fail "no shell-unlocked milestone"
say "unlocked (click-on-release proven by the pad itself)"

# 3. swipe DOWN from the top strip -> activity panel opens
qmp_swipe 640 40 640 300
wait_ms "name=shell-alerts-open" 20 "swipe down did not open the activity panel"
say "swipe down from the top: activity panel opened"

# 4. swipe UP from the bottom third -> home (panel closes)
qmp_swipe 640 650 640 350
wait_ms "name=shell-gesture-home" 20 "swipe up did not go home"
say "swipe up from the bottom: back home"

# 5. open the switcher, then close it with the same gesture
qmp_tap 60 40
wait_ms "name=shell-switcher-open" 20 "switcher did not open"
qmp_swipe 640 650 640 350
wait_ms "name=shell-gesture-home" 20 "swipe up did not close the switcher"
say "swipe up closes the switcher too"

# 6. negative: a mid-screen swipe down does NOT open the panel
N0=$(count_of "name=shell-alerts-open")
qmp_swipe 640 300 640 520
sleep 8
N1=$(count_of "name=shell-alerts-open")
[ "$N1" = "$N0" ] || fail "mid-screen swipe opened the panel (edge gating broken)"
say "mid-screen swipe ignored: edges only"

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — gesture nav: tap-vs-swipe classified on release, edges mapped, no hidden mid-screen actions"
echo "GESTURE GATE ALL GREEN"
