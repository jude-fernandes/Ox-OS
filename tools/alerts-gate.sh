#!/bin/sh
# Alerts gate: the live activity panel, end to end. A boot selftest
# grants itself and posts two notifications; the gate unlocks, taps
# the Alerts button, and requires the panel to report both (count=2);
# then Clear on a card dismisses it through notifd (count drops), and
# Alerts returns home. Artifact: compositor scene dump captured
# in-guest by alerts-selftest, pulled from the data image.
# usage: alerts-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-3600}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$OXDIR/tools/gate-lib.sh"   # chunk-54 guest-time waits
OUT=/tmp/ox-alg
LOG="$OUT/serial-alerts.log"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-al] %s\n' "$*"; }
fail() { printf '[ox-al] FAIL: %s\n' "$*" >&2; exit 1; }

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1

(OX_KERNEL_EXTRA=" ox.pm_drill=off" OX_GFX=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

qmp_tap() {
    python3 - "$1" "$2" <<'PYEOF'
import json, socket, sys, time
s = socket.socket(socket.AF_UNIX)
ok = False
for _ in range(15):
    try:
        s.connect("/tmp/ox-qmp"); ok = True; break
    except OSError:
        time.sleep(1)
if not ok:
    print("[ox-al] FATAL: /tmp/ox-qmp unreachable for 15s — QEMU died mid-gate", file=sys.stderr)
    sys.exit(3)
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
print("[ox-al] tap injected at %s,%s" % (sys.argv[1], sys.argv[2]))
PYEOF
}

qmp_pin() {
    python3 - "$1" <<'PYEOF'
import json, socket, sys, time
s = socket.socket(socket.AF_UNIX)
ok = False
for _ in range(15):
    try:
        s.connect("/tmp/ox-qmp"); ok = True; break
    except OSError:
        time.sleep(1)
if not ok:
    print("[ox-al] FATAL: /tmp/ox-qmp unreachable for 15s — QEMU died mid-gate", file=sys.stderr)
    sys.exit(3)
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
print("[ox-al] PIN digits + OK injected")
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

tap_until() {
    _sx="$1"; _sy="$2"; _pat="$3"; _rounds="$4"; _pollrounds="$5"; _label="$6"
    attempt=0
    while [ $attempt -lt "$_rounds" ]; do
        qmp_tap "$_sx" "$_sy"
        k=0
        while [ $k -lt "$_pollrounds" ]; do
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
        attempt=$((attempt + 1))
        say "$_label not observed (retry $((attempt + 1)))"
    done
    fail "$_label"
}

# 1. boot basics: the selftest granted itself and posted two alerts
i=0
while [ $i -lt 150 ]; do
    grep -aq "name=shell-home" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -aq "name=shell-locked" "$LOG" || fail "no shell-locked milestone"
wait_guest "name=alerts-seeded" 600000 1800 "alerts selftest did not seed notifications"
k=0
while [ $k -lt 450 ]; do
    grep -aq "name=resourced-tier-ok" "$LOG" 2>/dev/null && break
    grep -aq "name=resourced-tier-failed" "$LOG" 2>/dev/null && break
    sleep 2; k=$((k + 1))
done
grep -aq "name=resourced-tier-ok" "$LOG" 2>/dev/null \
    || grep -aq "name=resourced-tier-failed" "$LOG" 2>/dev/null \
    || fail "resourced drill never settled (neither tier-ok nor tier-failed observed)"
grep -aq "name=resourced-tier-failed" "$LOG" 2>/dev/null \
    && say "WARNING: resourced drill reported tier-failed (proceeding — alerts does not depend on tiers)"
say "resourced drill settled after $((k * 2))s"
sleep 3

# 2. PIN unlock — chunk 64: ONE injection, then an event-relative wait.
# Under load the guest chews a pad tap per ~20 guest-s, so a full PIN
# can take minutes of host time; re-injecting early only queues a
# second PIN behind the first and poisons the digit buffer. The count
# reads use grep -c's own zero (never `|| echo 0` — the dirty-zero
# bug), with `|| true` only to survive set -e.
attempt=0
UNLOCKED=no
while [ $attempt -lt 2 ]; do
    N0=$(grep -ac "name=shell-unlocked" "$LOG" || true)
    qmp_pin 1234
    k=0
    while [ $k -lt 300 ]; do
        N1=$(grep -ac "name=shell-unlocked" "$LOG" || true)
        [ "$N1" -gt "$N0" ] && break
        sleep 2; k=$((k + 1))
    done
    grep -aq "name=shell-unlocked" "$LOG" 2>/dev/null && { UNLOCKED=yes; break; }
    attempt=$((attempt + 1))
    say "unlock not observed yet (retry $((attempt + 1)))"
done
[ "$UNLOCKED" = yes ] || fail "no shell-unlocked milestone (2 injections x 600s)"
say "unlocked"

# 3. open the activity panel: both seeded notifications are listed
# (chunk 64: 30 poll-rounds — under load one tap's effect can take
# ~20 guest-s to land, so 16s polls starve the panel)
tap_until 471 652 "name=shell-alerts-open" 3 30 "Alerts panel did not open"
wait_ms "name=shell-alerts-shown count=2" 20 "panel did not list both notifications"
wait_ms "name=compositor-screendump path=/data/ox/artifacts/alerts-open.ppm" 30 "selftest did not capture the panel"
say "activity panel lists both notifications"

# 4. Clear on card 0: dismissed through notifd, count drops.
#    Card 0's Clear center: (832+60, 135+36+24) = (892, 195).
tap_until 892 195 "name=shell-alert-dismissed id=" 3 30 "Clear did not dismiss"
wait_ms "name=shell-alerts-shown count=1" 20 "panel did not drop to one card"
say "dismiss works: panel refreshed to one card"

# 5. Alerts returns home
tap_until 471 652 "name=shell-alerts-close" 3 30 "Alerts did not return home"
say "back on the home grid"

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1

# 6. artifact: pull the panel dump from the data image, assert pixels
debugfs -R "dump /ox/artifacts/alerts-open.ppm $OUT/alerts-open.ppm" "$PAYLOAD/data.img" >/dev/null 2>&1 \
    && [ -f "$OUT/alerts-open.ppm" ] \
    || fail "could not extract alerts-open.ppm from the data image"
python3 - "$OUT/alerts-open.ppm" <<'PYEOF'
import sys
p = sys.argv[1]
d = open(p, "rb").read()
assert d[:2] == b"P6", (p, "not a PPM")
i = d.find(b"255\n") + 4
px = d[i:]
nb = sum(1 for j in range(0, len(px), 3) if px[j] or px[j+1] or px[j+2])
assert nb > 10000, (p, f"only {nb} non-black pixels — blank dump")
print(f"[ox-al] {p}: {nb} non-black pixels — real content")
PYEOF
say "artifact: $OUT/alerts-open.ppm (panel with both cards)"
say "ALL GREEN — activity panel: seeded, listed, dismissed, refreshed"
echo "ALERTS GATE ALL GREEN"
