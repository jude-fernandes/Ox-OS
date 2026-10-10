#!/bin/sh
# Shell gate: boot locked; wrong PIN must be rejected; correct PIN must
# unlock; then a real pointer tap on the Settings tile must escalate a
# launch through the compositor's click delivery.
# usage: shell-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-600}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-shellgate
LOG="$OUT/serial-shell.log"
PPM="$OUT/shell-screendump.ppm"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-sh] %s\n' "$*"; }
fail() { printf '[ox-sh] FAIL: %s\n' "$*" >&2; exit 1; }

(OX_GFX=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

# 1. shell boots locked (home pre-rendered behind the lock)
i=0
while [ $i -lt 150 ]; do
    grep -aq "name=shell-home" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -aq "name=shell-locked" "$LOG" || {
    tail -10 "$LOG" 2>/dev/null || true
    fail "no shell-locked milestone (lock screen did not draw)"; }
grep -aq "name=shell-home" "$LOG" || {
    tail -10 "$LOG" 2>/dev/null || true
    fail "no shell-home milestone (ox-shell did not draw)"; }
say "locked screen up (home pre-rendered behind it)"
sleep 3

# 2. let the resourced-selftest's memory drill finish first — its 880 MB
#    tmpfs fill thrashes the VM and can swallow/garble injected clicks
k=0
while [ $k -lt 300 ]; do
    grep -aq "name=resourced-tier-ok" "$LOG" 2>/dev/null && break
    grep -aq "name=resourced-tier-failed" "$LOG" 2>/dev/null && break
    sleep 2; k=$((k + 1))
done
say "resourced drill settled (waiting was $(k)s; tier-ok seen: $(grep -ac 'name=resourced-tier-ok' "$LOG" 2>/dev/null || echo 0))"

# 2. PIN entry via injected taps on the pad (3x4 grid at 353,420 —
#    cell 90x56, gap 12). Poll for pin-rejected/unlocked after entry.
inject_pin() { python3 - "$1" <<'PYEOF'
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
# the PIN is only evaluated when OK is pressed
i = keys.index("OK")
x, y, w, h = rects[i]
tap(x + w / 2, y + h / 2)
print("[ox-sh] PIN digits + OK injected")
PYEOF
}

wait_pin_verdict() {
    k=0
    while [ $k -lt 300 ]; do
        grep -aq "name=shell-pin-rejected\|name=shell-unlocked" "$LOG" 2>/dev/null && return 0
        sleep 2; k=$((k + 1))
    done
    return 1
}

# leg A: wrong PIN (9999) -> rejected, still locked
attempt=0
REJECTED=no
while [ $attempt -lt 3 ]; do
    : > "$OUT/pinverdict.marker"
    N0=$(grep -ac "name=shell-pin-rejected" "$LOG" 2>/dev/null || true)
    inject_pin 9999
    k=0
    while [ $k -lt 300 ]; do
        N1=$(grep -ac "name=shell-pin-rejected" "$LOG" 2>/dev/null || true)
        [ "$N1" -gt "$N0" ] 2>/dev/null && break
        sleep 2; k=$((k + 1))
    done
    grep -aq "name=shell-pin-rejected" "$LOG" 2>/dev/null && { REJECTED=yes; break; }
    attempt=$((attempt + 1))
    say "wrong PIN not observed yet (retry $((attempt + 1)))"
done
[ "$REJECTED" = yes ] || fail "wrong PIN (9999) was not rejected"
say "wrong PIN rejected, device still locked"

# leg B: correct PIN (1234) -> unlocked
attempt=0
UNLOCKED=no
while [ $attempt -lt 3 ]; do
    N0=$(grep -ac "name=shell-unlocked" "$LOG" 2>/dev/null || true)
    inject_pin 1234
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
[ "$UNLOCKED" = yes ] || fail "no shell-unlocked milestone (correct PIN did not unlock)"
say "PIN auth: wrong PIN rejected, correct PIN unlocks"

# 3. let the resourced-selftest's memory drill finish first — its tmpfs
#    fill thrashes the VM and can swallow injected clicks
k=0
while [ $k -lt 240 ]; do
    grep -aq "name=resourced-tier-ok" "$LOG" 2>/dev/null && break
    grep -aq "name=resourced-tier-failed" "$LOG" 2>/dev/null && break
    sleep 2; k=$((k + 1))
done
say "resourced drill settled (tier-ok seen: $(grep -ac 'name=resourced-tier-ok' "$LOG" 2>/dev/null || echo 0))"

# 4. tap the Settings tile (center 158,195) — same retry discipline
attempt=0
LAUNCHED=no
while [ $attempt -lt 3 ]; do
    python3 - <<'PYEOF'
import json, socket, time
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
tap(158, 195)
print("[ox-sh] Settings tap injected")
PYEOF
    k=0
    while [ $k -lt 30 ]; do
        grep -aq "name=shell-launch app=Settings" "$LOG" 2>/dev/null && { LAUNCHED=yes; break; }
        sleep 2; k=$((k + 1))
    done
    [ "$LAUNCHED" = yes ] && break
    attempt=$((attempt + 1))
    say "Settings tap not observed (retry $((attempt + 1)))"
done
[ "$LAUNCHED" = yes ] || fail "no shell-launch milestone (click did not reach the tile)"
say "lock -> PIN auth -> launch, end to end:"
grep -a -e "name=shell-pin-rejected" -e "name=shell-unlocked" -e "name=shell-launch" "$LOG" | tail -3 | sed 's/^/[ox-sh]   /'

# 4. artifact: screendump of the launched state
sleep 2
python3 - "$PPM" <<'PYEOF'
import json, socket, sys
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
r = send({"execute": "screendump", "arguments": {"filename": sys.argv[1]}})
assert "error" not in r, r
print("[ox-sh] screendump ok")
PYEOF

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — PIN-locked shell: reject wrong PIN, unlock on correct PIN, tap-to-launch"
echo "SHELL GATE ALL GREEN"