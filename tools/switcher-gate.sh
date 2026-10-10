#!/bin/sh
# Switcher gate: recents + close, end to end. Unlock -> launch Settings
# from its tile (it runs and covers the shell) -> tap the top-left
# switcher trigger (reachable above any app) -> the switcher lists the
# RUNNING app -> Close on its card -> intentd stops the app (SIGKILL),
# releases its wake lock, and the switcher refreshes without the card
# -> Recents returns home. Artifacts: compositor scene dumps captured
# in-guest by switcher-selftest, pulled from the data image.
# usage: switcher-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-3600}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$OXDIR/tools/gate-lib.sh"   # chunk-54 guest-time waits
OUT=/tmp/ox-swg
LOG="$OUT/serial-switcher.log"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-sw] %s\n' "$*"; }
fail() { printf '[ox-sw] FAIL: %s\n' "$*" >&2; exit 1; }

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1

(OX_KERNEL_EXTRA=" ox.pm_drill=off" OX_GFX=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
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
print("[ox-sw] tap injected at %s,%s" % (sys.argv[1], sys.argv[2]))
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
print("[ox-sw] PIN digits + OK injected")
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

# 1. boot basics
i=0
while [ $i -lt 150 ]; do
    grep -aq "name=shell-home" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -aq "name=shell-locked" "$LOG" || fail "no shell-locked milestone"
grep -aq "name=intentd-ready" "$LOG" || fail "no intentd-ready milestone"
wait_guest "name=pkg-flow-ok" 1200000 1800 "pkg selftest did not settle"
k=0
while [ $k -lt 450 ]; do
    grep -aq "name=resourced-tier-ok" "$LOG" 2>/dev/null && break
    grep -aq "name=resourced-tier-failed" "$LOG" 2>/dev/null && break
    sleep 2; k=$((k + 1))
done
grep -aq "name=resourced-tier-ok" "$LOG" 2>/dev/null \
    || grep -aq "name=resourced-tier-failed" "$LOG" 2>/dev/null \
    || fail "resourced drill never settled (neither tier-ok nor tier-failed observed)"
say "resourced drill settled after $((k * 2))s"
sleep 3

# 2. PIN unlock — chunk 64: one injection per attempt, event-relative
# 600s windows (a pad click can take ~20 guest-s to land under load),
# dirty-zero-free counts, and a drain so a lagging click from this
# attempt cannot poison the next one.
attempt=0
UNLOCKED=no
while [ $attempt -lt 3 ]; do
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
    sleep 30
done
[ "$UNLOCKED" = yes ] || fail "no shell-unlocked milestone"
say "unlocked"

# 3. launch Settings from its tile (it runs and covers the shell)
tap_until 158 195 "name=settings-ready" 3 30 "Settings did not launch"
wait_guest "name=intent-start app=Settings" 600000 1800 "launch did not reach intentd"
say "Settings launched and running"

# 4. open the switcher from the top-left trigger (reachable above apps)
tap_until 60 40 "name=shell-switcher-open" 3 30 "switcher did not open"
wait_guest "name=compositor-screendump path=/data/ox/artifacts/switcher-open.ppm" 600000 1800 "selftest did not capture the open switcher"
say "switcher open with the running app listed"

# 5. Close on the Settings card: intentd stops the app, releases its
#    wake lock, and the switcher refreshes without the card.
#    Card 0's Close button center: (832+60, 135+24+24) = (892, 183).
tap_until 892 183 "name=shell-app-close app=Settings" 3 30 "Settings card was not closed"
wait_guest "name=intent-stop app=Settings pid=" 600000 1800 "intentd did not stop the app"
wait_guest "name=wake-lock-release id=app-settings" 600000 1800 "killed app's wake lock leaked"
wait_guest "name=shell-switcher-refresh" 600000 1800 "switcher did not refresh after the close"
wait_guest "name=switcher-selftest-done" 600000 1800 "selftest did not finish"
# stop() reaps the child synchronously — no intent-exit may appear for
# it afterwards (an exit here would mean a zombie was left behind)
sleep 8
grep -aq "name=intent-exit app=Settings" "$LOG" 2>/dev/null \
    && fail "stopped app was reaped asynchronously (zombie left behind)"
say "Settings closed from the switcher: stopped, wake lock released, no zombie"

# 6. Recents returns home
tap_until 297 652 "name=shell-switcher-close" 3 30 "Recents did not return home"
say "back on the home grid"

# 7. the stopped app is really gone: relaunch it fresh
N0=$(grep -ac "name=intent-start app=Settings" "$LOG" 2>/dev/null || echo 0)
tap_until 158 195 "name=settings-ready" 3 30 "Settings did not relaunch"
sleep 5
N1=$(grep -ac "name=intent-start app=Settings" "$LOG" 2>/dev/null || echo 0)
[ "$N1" -gt "$N0" ] || fail "Settings relaunch did not reach intentd"
say "relaunch works after the close"

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1

# 8. artifacts: pull the scene dumps from the data image, assert real
#    pixels (image root mounts at /data, so paths here drop the prefix)
for f in switcher-open switcher-closed; do
    debugfs -R "dump /ox/artifacts/$f.ppm $OUT/$f.ppm" "$PAYLOAD/data.img" >/dev/null 2>&1 \
        && [ -f "$OUT/$f.ppm" ] \
        || fail "could not extract $f.ppm from the data image"
done
python3 - "$OUT/switcher-open.ppm" "$OUT/switcher-closed.ppm" <<'PYEOF'
import sys
for p in sys.argv[1:3]:
    d = open(p, "rb").read()
    assert d[:2] == b"P6", (p, "not a PPM")
    i = d.find(b"255\n") + 4
    px = d[i:]
    nb = sum(1 for j in range(0, len(px), 3) if px[j] or px[j+1] or px[j+2])
    assert nb > 10000, (p, f"only {nb} non-black pixels — blank dump")
    print(f"[ox-sw] {p}: {nb} non-black pixels — real content")
PYEOF
say "artifacts: $OUT/switcher-open.ppm (running app card), $OUT/switcher-closed.ppm (card gone)"
say "ALL GREEN — switcher: recents reachable above apps, running list honest, close stops + unlocks + reaps"
echo "SWITCHER GATE ALL GREEN"
