#!/bin/sh
# App-model gate: PIN-unlock, tap the Settings tile, and require the
# FULL app lifecycle through intentd: shell-intent ok=true -> intentd
# spawns ox-settings (intent-start) -> app draws (settings-ready) ->
# tap its airplane toggle (settings-toggle state=on) -> screendump ->
# tap Close (settings-close) -> intentd reaps the exit (intent-exit).
# usage: app-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-900}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-appgate
LOG="$OUT/serial-app.log"
PPM="$OUT/app-screendump.ppm"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-app] %s\n' "$*"; }
fail() { printf '[ox-app] FAIL: %s\n' "$*" >&2; exit 1; }

# Pre-boot hygiene: a stale QEMU from an earlier failed run still holds
# the VNC port (its `timeout` may outlive this run's start) and the new
# instance would die instantly on "Address already in use".
pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1

(OX_GFX=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

# qmp_tap SX SY — inject one absolute-pointer tap through the QMP socket
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
print("[ox-app] tap injected at %s,%s" % (sys.argv[1], sys.argv[2]))
PYEOF
}

# qmp_pin PIN — tap the pad digits, then OK (the PIN is only evaluated
# on OK; the pad grid is at 353,420, cells 90x56, gap 12)
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
print("[ox-app] PIN digits + OK injected")
PYEOF
}

# 1. boot locked, intentd supervised
i=0
while [ $i -lt 150 ]; do
    grep -aq "name=shell-home" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -aq "name=shell-locked" "$LOG" || fail "no shell-locked milestone (lock screen did not draw)"
grep -aq "name=shell-home" "$LOG" || fail "no shell-home milestone (ox-shell did not draw)"
grep -aq "name=intentd-ready" "$LOG" || fail "no intentd-ready milestone (intentd not supervised)"
say "locked shell up, intentd supervised"
sleep 3

# 2. let the resourced memory drill settle — its 880 MB tmpfs fill
#    thrashes the VM and can swallow injected clicks
k=0
while [ $k -lt 300 ]; do
    grep -aq "name=resourced-tier-ok" "$LOG" 2>/dev/null && break
    grep -aq "name=resourced-tier-failed" "$LOG" 2>/dev/null && break
    sleep 2; k=$((k + 1))
done
say "resourced drill settled after $((k * 2))s"

# 3. unlock with the DEV PIN
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
[ "$UNLOCKED" = yes ] || fail "no shell-unlocked milestone (correct PIN did not unlock)"
say "unlocked with PIN"

# 4. tap the Settings tile (center 158,195): the tap must escalate into
#    intentd spawning the app, and the app must draw
attempt=0
READY=no
while [ $attempt -lt 3 ]; do
    qmp_tap 158 195
    k=0
    while [ $k -lt 30 ]; do
        grep -aq "name=settings-ready" "$LOG" 2>/dev/null && { READY=yes; break; }
        sleep 2; k=$((k + 1))
    done
    [ "$READY" = yes ] && break
    attempt=$((attempt + 1))
    say "settings-ready not observed (retry $((attempt + 1)))"
done
[ "$READY" = yes ] || fail "app did not become ready through the intent chain"
say "tile tap -> shell-intent -> intent-start -> settings-ready:"
grep -a -e "name=shell-intent" -e "name=intent-start" -e "name=settings-ready" "$LOG" | tail -3 | sed 's/^/[ox-app]   /'

# 5. tap the airplane toggle. Settings window at screen (190,80); its
#    airplane button center is window (777,562) -> screen (967,642)
attempt=0
TOGGLED=no
while [ $attempt -lt 3 ]; do
    qmp_tap 967 642
    k=0
    while [ $k -lt 20 ]; do
        grep -aq "name=settings-toggle state=on" "$LOG" 2>/dev/null && { TOGGLED=yes; break; }
        sleep 2; k=$((k + 1))
    done
    [ "$TOGGLED" = yes ] && break
    attempt=$((attempt + 1))
    say "toggle not observed (retry $((attempt + 1)))"
done
[ "$TOGGLED" = yes ] || fail "airplane toggle click did not reach the app"
say "airplane toggle: on"

# 6. artifact: screendump of the running, toggled app state
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
print("[ox-app] screendump ok")
PYEOF

# 7. tap Close: button center is window (777,632) -> screen (967,712)
attempt=0
CLOSED=no
while [ $attempt -lt 3 ]; do
    qmp_tap 967 712
    k=0
    while [ $k -lt 20 ]; do
        grep -aq "name=settings-close" "$LOG" 2>/dev/null && { CLOSED=yes; break; }
        sleep 2; k=$((k + 1))
    done
    [ "$CLOSED" = yes ] && break
    attempt=$((attempt + 1))
    say "close not observed (retry $((attempt + 1)))"
done
[ "$CLOSED" = yes ] || fail "Close click did not reach the app"
say "app exited via Close"

# 8. intentd must reap the exit
k=0
while [ $k -lt 30 ]; do
    grep -aq "intent-exit app=Settings" "$LOG" 2>/dev/null && break
    sleep 2; k=$((k + 1))
done
grep -aq "intent-exit app=Settings" "$LOG" 2>/dev/null || fail "intentd did not reap the app exit"
say "intentd reaped the app exit"

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — app model: tile tap -> intentd -> app draws, toggles, closes, reaped"
echo "APP GATE ALL GREEN"
