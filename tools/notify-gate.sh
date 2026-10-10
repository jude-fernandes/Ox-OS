#!/bin/sh
# Grants-panel gate: the USER-facing permission story, all through the
# UI. At boot the installed Hello app posts a notification and is
# denied (manifest-bound deny). The gate then: PIN-unlocks -> opens
# Settings -> Permissions -> taps the Hello entry (deny -> grant,
# persisted) -> closes Settings -> relaunches Hello from its dynamic
# tile -> the notification is ACCEPTED (hello-notify-ok).
# usage: notify-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-900}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-notifygate
LOG="$OUT/serial-notify.log"
PPM="$OUT/notify-screendump.ppm"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-notify] %s\n' "$*"; }
fail() { printf '[ox-notify] FAIL: %s\n' "$*" >&2; exit 1; }

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
print("[ox-notify] tap injected at %s,%s" % (sys.argv[1], sys.argv[2]))
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
print("[ox-notify] PIN digits + OK injected")
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
    # tap_until SX SY GREP MAX_ROUNDS LABEL — tap with retry until the
    # milestone appears
    _sx="$1"; _sy="$2"; _pat="$3"; _rounds="$4"; _label="$5"
    attempt=0
    while [ $attempt -lt "$_rounds" ]; do
        qmp_tap "$_sx" "$_sy"
        k=0
        while [ $k -lt 20 ]; do
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

# 1. boot: the app's first notification must be DENIED (bound deny)
i=0
while [ $i -lt 150 ]; do
    grep -aq "name=shell-home" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -aq "name=shell-locked" "$LOG" || fail "no shell-locked milestone"
wait_ms "name=hello-notify-denied" 90 "installed app's notification was not denied at boot"
say "boot-time proof: Hello's notification denied (manifest-bound deny)"
k=0
while [ $k -lt 300 ]; do
    grep -aq "name=resourced-tier-ok" "$LOG" 2>/dev/null && break
    grep -aq "name=resourced-tier-failed" "$LOG" 2>/dev/null && break
    sleep 2; k=$((k + 1))
done
say "resourced drill settled after $((k * 2))s"
sleep 3

# 2. PIN unlock
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
say "unlocked"

# 3. Settings -> Permissions panel
tap_until 158 195 "name=settings-ready" 3 "Settings did not launch"
say "Settings open"
tap_until 487 642 "name=perms-open" 3 "Permissions panel did not open"
say "grants panel open"

# 4. tap the Hello entry (its manifest bin ox-hello post-chunk-68):
#    the row's Y comes from the panel's OWN perm-row journal (the
#    grid-dyn lesson — entry order shifts as grant identities change)
say "grants panel open"
i=0
ROWY=""
while [ $i -lt 60 ]; do
    ROWY=$(grep -ao "name=perm-row row=[0-9]* app=ox-hello perm=post-notification mode=deny y=[0-9]*" "$LOG" 2>/dev/null | tail -1 | grep -o "y=[0-9]*" | cut -d= -f2)
    [ -n "$ROWY" ] && break
    sleep 2; i=$((i + 1))
done
[ -n "$ROWY" ] || fail "panel never journalled the ox-hello row"
# the journal y is WINDOW-space (row center); the Settings window's
# scene offset comes from its own window-new journal (chunk 68: the
# Oct-5 mis-tap toggled the row one pitch up — screen vs window space)
WY=$(grep -ao "window-new id=[0-9]* x=[0-9]* y=[0-9]* w=900 h=680" "$LOG" 2>/dev/null | tail -1 | grep -o "y=[0-9]*" | cut -d= -f2)
[ -n "$WY" ] || WY=0
ROWY=$((WY + ROWY))
say "ox-hello row center at screen y=$ROWY (window $WY + journal)"
tap_until 640 "$ROWY" "name=perm-toggled app=ox-hello permission=post-notification mode=grant" 3 "Hello entry toggle did not grant"
say "user granted post-notification to Hello (persisted)"

# 5. artifact: the grants panel
sleep 2
python3 - "$PPM" <<'PYEOF'
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
r = send({"execute": "screendump", "arguments": {"filename": sys.argv[1]}})
assert "error" not in r, r
print("[ox-notify] screendump ok")
PYEOF

# 6. back to settings, close, relaunch Hello from its dynamic tile —
#    the slot comes from the shell's home-grid journal (the grid-dyn
#    lesson: the fixed (158,483) hit Camera's tile when Hello landed in
#    dynamic slot 3; dyn_tile_rect center = (48+((i-1)%2)*244+110,
#    423+((i-1)/2)*112+44))
tap_until 313 712 "name=perms-back" 3 "Back did not return to Settings"
tap_until 967 712 "name=settings-close" 3 "Settings did not close"
i=0
HX=""
HY=""
while [ $i -lt 90 ]; do
    LINE=$(grep -a "name=home-grid dyn=" "$LOG" 2>/dev/null | tail -1 | sed "s/.*dyn=//" | tr -d "\r")
    HX=$(printf "%s" "$LINE" | tr "," "\n" | grep -nx "Hello" | cut -d: -f1)
    [ -n "$HX" ] && break
    sleep 2; i=$((i + 1))
done
[ -n "$HX" ] || fail "Hello not in the rendered dynamic row: $LINE"
[ "$HX" -le 4 ] || fail "Hello at dynamic slot $HX — beyond the 4 rendered tiles"
HTX=$(( 48 + ( (HX - 1) % 2 ) * 244 + 110 ))
HTY=$(( 423 + ( (HX - 1) / 2 ) * 112 + 44 ))
say "Hello at dynamic slot $HX -> tap ($HTX,$HTY)"
tap_until "$HTX" "$HTY" "name=hello-notify-ok" 3 "relaunched Hello's notification was not accepted"
say "relaunch: Hello's notification ACCEPTED after the user grant"

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — deny at install, user grant through the UI, accept on relaunch"
echo "NOTIFY GATE ALL GREEN"
