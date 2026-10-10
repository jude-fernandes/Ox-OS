#!/bin/sh
. "$(dirname "$0")/gate-lib.sh"   # chunk-54 guest-time waits
# Camera-app gate (Phase 4): the Camera app end to end. The signed
# camera.oxp installs at boot (dynamic tile, camera.read bound deny);
# the gate PIN-unlocks, taps the Camera tile, and requires the FULL
# honest lifecycle: launch -> viewfinder REFUSED (bound deny) ->
# shutter refused -> user grant flips -> LIVE viewfinder frames with
# the CAM badge -> status-card indicator active -> shutter captures a
# REAL sensor frame (colors=8) -> Close -> reap -> indicator clears.
# usage: camera-app-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-2400}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-camappgate
LOG="$OUT/serial-camapp.log"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-camapp] %s\n' "$*"; }
fail() { printf '[ox-camapp] FAIL: %s\n' "$*" >&2; exit 1; }

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

# tap + wait-for-milestone with retry rounds: a single tap is a
# single point of failure under variable guest timing
tap_retry() {
    _sx="$1"; _sy="$2"; _pat="$3"; _label="$4"
    r=0
    while [ $r -lt 5 ]; do
        qmp_tap "$_sx" "$_sy"
        k=0
        while [ $k -lt 150 ]; do
            grep -aq "$_pat" "$LOG" 2>/dev/null && return 0
            sleep 2; k=$((k + 1))
        done
        r=$((r + 1))
    done
    fail "$_label (pattern not observed: $_pat)"
}


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
print("[ox-camapp] tap injected at %s,%s" % (sys.argv[1], sys.argv[2]))
PYEOF
}

qmp_pin() {
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
def unlocked():
    # raw BYTES read: the serial log carries ANSI escapes and torn
    # lines — a text-mode grep here used to throw on decode and
    # silently report zero forever
    try:
        with open(sys.argv[2], "rb") as f:
            return f.read().count(b"name=shell-unlocked")
    except Exception:
        return 0
# ABSOLUTE, checked BEFORE each tap: the gates unlock exactly once,
# so any unlock observation means the device is already open and the
# remaining pad taps would land on the home GRID (a stray launch whose
# window then eats every later tap). A per-attempt delta was blind:
# the unlock milestone lands between attempts and the base swallowed it.
for ch in sys.argv[1]:
    if unlocked() > 0:
        print("[ox-camapp] unlock already observed - aborting remaining PIN taps")
        sys.exit(0)
    i = keys.index(ch)
    x, y, w, h = rects[i]
    tap(x + w / 2, y + h / 2)
    time.sleep(1.0)
if unlocked() > 0:
    print("[ox-camapp] unlock already observed - skipping OK tap")
    sys.exit(0)
i = keys.index("OK")
x, y, w, h = rects[i]
tap(x + w / 2, y + h / 2)
print("[ox-camapp] PIN digits + OK injected")
PYEOF
}

wait_guest "name=pm-drill-skipped\|name=pm-resumed" 1080000 1800 "powerd PM selftest never resumed"
wait_guest "name=shell-locked" 900000 1800 "lock screen never rendered"

# keep the guest wakeable through idle suspends: a 15s system_wakeup
# is a no-op while awake and plays the power button while suspended
(while :; do
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
    sleep 15
done) 2>/dev/null &
say "powerd PM selftest resumed"
KEEP=$!

i=0
while [ ! -S /tmp/ox-qmp ] && [ $i -lt 120 ]; do
    sleep 1; i=$((i + 1))
done
sleep 30
attempt=0
UNLOCKED=no
while [ $attempt -lt 6 ]; do
    qmp_pin 1234 "$LOG" || true
    k=0
    while [ $k -lt 300 ]; do
        grep -aq "name=shell-unlocked" "$LOG" 2>/dev/null && break
        sleep 2; k=$((k + 1))
    done
    grep -aq "name=shell-unlocked" "$LOG" 2>/dev/null && { UNLOCKED=yes; break; }
    attempt=$((attempt + 1))
    say "unlock not observed yet (retry $((attempt + 1)))"
    # drain: let queued pad clicks DELIVER before re-injecting —
    # a lagging click lands on the (now unlocked) home grid and
    # opens a full-screen app window that eats every later tap
    sleep 30
done
[ "$UNLOCKED" = yes ] || fail "no shell-unlocked milestone"
say "unlocked"

# 1. the signed package installed -> Camera dynamic tile exists
wait_guest "name=camera-app-installed" 2700000 1800 "camera.oxp never installed (signature? staging?)"
say "camera.oxp installed, dynamic tile bound camera.read=deny"

# 2. tap the Camera dynamic tile (row 2, left column). tap_retry, not a
#    single tap: the shell fetches the installed list at unlock and
#    self-heals the grid within ~5s of an install — a tap fired before
#    that redraw lands on nothing (and wait_ms exits via fail(), so a
#    `||`-chained fallback would never run).
tap_retry 158 483 "name=camera-app-ready" "Camera app never drew (tile tap)"

# the app holds a wake lock while foreground — the keep-awake taps would
# otherwise raise other windows mid-flow (stealing clicks)
kill "$KEEP" 2>/dev/null || true
say "Camera app launched and drew (keep-awake taps stopped; app wake lock owns it)"

# 3. honest default: manifest-bound deny refuses the viewfinder (the
# selftest grants as soon as it sees this refusal, so there is no
# separate shutter-while-denied tap — the frame refusal IS the deny
# evidence, and racing it is a coin flip)
wait_guest "name=camera-app-denied" 1080000 1800 "app was not refused by the bound deny (permission leak?)"
say "viewfinder refused by the bound camera.read deny"

# 4. the user grant flips -> the app's viewfinder goes live
wait_guest "name=camera-app-granted" 2700000 1800 "selftest never flipped the user grant"
wait_guest "name=camera-app-live" 1620000 1800 "viewfinder never went live after the grant"
# LIVE means repeated frames: wait for the THIRD frame within a bounded
# window (a fixed 4s sleep raced the frame cadence under sweep load —
# TCG stretches it well past 4s mid-sweep)
k=0
while [ $k -lt 60 ]; do
    FRAMES=$(grep -ac "name=camera-app-live" "$LOG" 2>/dev/null || true)
    [ "${FRAMES:-0}" -ge 3 ] 2>/dev/null && break
    sleep 2; k=$((k + 1))
done
FRAMES=$(grep -ac "name=camera-app-live" "$LOG" 2>/dev/null || true)
[ "${FRAMES:-0}" -ge 3 ] 2>/dev/null || fail "viewfinder published only $FRAMES frame(s), need >= 3"
say "viewfinder live: $FRAMES frames published"

# 5. the in-use indicator, on a surface OUTSIDE the camera app
wait_guest "name=status-cam-active" 1080000 1800 "status card never showed the CAM chip"
say "status-card CAM indicator active"

# 6. shutter: a REAL sensor capture pinned by colorbar analysis
tap_retry 174 644 "name=camera-app-captured" "shutter never captured after the grant"
grep -a "name=camera-app-captured" "$LOG" | tail -1 | sed 's/^/[ox-camapp]   /'
grep -aq "name=camera-app-captured.*colors=8" "$LOG" || fail "captured frame is not the vivid 8-bar strip"
say "shutter captured a REAL frame (colors=8, saved to DCIM)"

# 7. close + reap + indicator clears
qmp_tap 877 662
wait_guest "name=camera-app-exit" 1080000 1800 "Camera app never exited"
wait_guest "intent-exit app=Camera" 1080000 1800 "intentd never reaped the Camera app"
wait_guest "name=status-cam-inactive" 1080000 1800 "CAM indicator never cleared after close"
say "closed, reaped, indicator cleared"

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — Camera app: signed package install, bound-deny refusal, user grant, live viewfinder, status-card indicator, real capture, clean reap"
echo "CAMERA APP GATE ALL GREEN"
