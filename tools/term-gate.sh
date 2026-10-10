#!/bin/sh
# Terminal gate: the keyboard path, end to end. PIN-unlock, tap the
# Terminal tile, require term-ready, CLICK the terminal window (focus
# must be explicit — creation never steals it), TYPE a command over the
# QMP keyboard route, require term-exec with the typed line, screendump,
# then Close -> term-exit -> intentd reap.
# usage: term-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-900}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-termgate
LOG="$OUT/serial-term.log"
PPM="$OUT/term-screendump.ppm"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-term] %s\n' "$*"; }
fail() { printf '[ox-term] FAIL: %s\n' "$*" >&2; exit 1; }

# stale QEMU from an earlier run still holds the VNC port
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
print("[ox-term] tap injected at %s,%s" % (sys.argv[1], sys.argv[2]))
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
print("[ox-term] PIN digits + OK injected")
PYEOF
}

mon_type() {
    python3 - "$1" <<'PYEOF'
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.connect("/tmp/ox-qmon")
s.settimeout(2)
def drain():
    try:
        return s.recv(65536).decode(errors="replace")
    except socket.timeout:
        return ""
drain()
Q = {chr(c): chr(c) for c in range(ord("a"), ord("z") + 1)}
Q.update({str(d): str(d) for d in range(10)})
Q.update({" ": "spc", "-": "minus", ".": "dot", "/": "slash", "\n": "ret"})
for ch in sys.argv[1]:
    s.send(f"sendkey {Q[ch]}\n".encode())
    time.sleep(0.06)
    drain()
# the command only runs on Enter
s.send(b"sendkey ret\n")
time.sleep(0.06)
drain()
print("[ox-term] typed: %s <Enter>" % sys.argv[1])
PYEOF
}

# clear whatever is on the prompt line (a retry must not append onto
# stale input): 80 backspaces
mon_bs() {
    python3 - <<'PYEOF'
import socket, time
s = socket.socket(socket.AF_UNIX)
s.connect("/tmp/ox-qmon")
s.settimeout(2)
def drain():
    try:
        return s.recv(65536).decode(errors="replace")
    except socket.timeout:
        return ""
drain()
for n in range(24):
    s.send(b"sendkey backspace\n")
    time.sleep(0.03)
    drain()
print("[ox-term] prompt line cleared")
PYEOF
}

# f1 is deliberately UNMAPPED in oxcom: if it arrives at the guest,
# oxcom journals "key code=59 unmapped" — a pure delivery probe that
# does not depend on focus or any app.
mon_probe() {
    python3 - <<'PYEOF'
import socket, time
s = socket.socket(socket.AF_UNIX)
s.connect("/tmp/ox-qmon")
s.settimeout(1.5)
def drain():
    try:
        return s.recv(65536).decode(errors="replace")
    except socket.timeout:
        return ""
drain()
s.send(b"sendkey f1\n")
time.sleep(0.2)
drain()
print("[ox-term] f1 delivery probe sent")
PYEOF
}

# 1. boot locked, intentd supervised
i=0
while [ $i -lt 150 ]; do
    grep -aq "name=shell-home" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -aq "name=shell-locked" "$LOG" || fail "no shell-locked milestone"
grep -aq "name=shell-home" "$LOG" || fail "no shell-home milestone"
grep -aq "name=intentd-ready" "$LOG" || fail "no intentd-ready milestone"
say "locked shell up, intentd supervised"
mon_probe
sleep 3

# 2. let the resourced memory drill settle
k=0
while [ $k -lt 300 ]; do
    grep -aq "name=resourced-tier-ok" "$LOG" 2>/dev/null && break
    grep -aq "name=resourced-tier-failed" "$LOG" 2>/dev/null && break
    [ $((k % 15)) -eq 14 ] && mon_probe
    sleep 2; k=$((k + 1))
done
say "resourced drill settled after $((k * 2))s"
mon_probe

# 3. PIN unlock
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
say "unlocked with PIN"

# 4. tap the Terminal tile (3rd tile, center 158,339) -> term-ready
attempt=0
READY=no
while [ $attempt -lt 3 ]; do
    qmp_tap 158 339
    k=0
    while [ $k -lt 30 ]; do
        grep -aq "name=term-ready" "$LOG" 2>/dev/null && { READY=yes; break; }
        sleep 2; k=$((k + 1))
    done
    [ "$READY" = yes ] && break
    attempt=$((attempt + 1))
    say "term-ready not observed (retry $((attempt + 1)))"
done
[ "$READY" = yes ] || fail "Terminal did not become ready through the intent chain"
say "Terminal launched and drew"
grep -a -e "name=shell-intent app=Terminal" -e "name=intent-start app=Terminal" -e "name=term-ready" "$LOG" | tail -3 | sed 's/^/[ox-term]   /'

# 5. click inside the terminal window to FOCUS it (creation never
#    steals focus; keys route to the focused window), then type
attempt=0
EXECED=no
while [ $attempt -lt 3 ]; do
    qmp_tap 400 400          # focus click (also a harmless click to the app)
    sleep 2
    mon_probe
    mon_bs
    mon_probe
    mon_type "echo ox-term-gate"
    mon_probe
    k=0
    while [ $k -lt 300 ]; do
        grep -aq "name=term-exec cmd=echo ox-term-gate" "$LOG" 2>/dev/null && { EXECED=yes; break; }
        sleep 2; k=$((k + 1))
    done
    [ "$EXECED" = yes ] && break
    attempt=$((attempt + 1))
    say "term-exec not observed (retry $((attempt + 1)))"
done
[ "$EXECED" = yes ] || fail "typed command never ran (keyboard focus or delivery failed)"
say "keyboard path: typed command executed by the Terminal app"

# 6. artifact: screendump of the terminal with the command output
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
print("[ox-term] screendump ok")
PYEOF

# 7. tap Close (window (802,568) 150x48 -> center screen 937,652)
attempt=0
EXITED=no
while [ $attempt -lt 3 ]; do
    qmp_tap 937 652
    k=0
    while [ $k -lt 20 ]; do
        grep -aq "name=term-exit" "$LOG" 2>/dev/null && { EXITED=yes; break; }
        sleep 2; k=$((k + 1))
    done
    [ "$EXITED" = yes ] && break
    attempt=$((attempt + 1))
    say "term-exit not observed (retry $((attempt + 1)))"
done
[ "$EXITED" = yes ] || fail "Close click did not reach the Terminal app"

# 8. intentd must reap the exit
k=0
while [ $k -lt 30 ]; do
    grep -aq "intent-exit app=Terminal" "$LOG" 2>/dev/null && break
    sleep 2; k=$((k + 1))
done
grep -aq "intent-exit app=Terminal" "$LOG" 2>/dev/null || fail "intentd did not reap the Terminal exit"
say "intentd reaped the Terminal exit"

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — keyboard path: launch, focus, type, execute, close, reap"
echo "TERM GATE ALL GREEN"
