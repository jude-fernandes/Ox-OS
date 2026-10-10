#!/bin/sh
# Files gate: the third packaged app, end to end. PIN-unlock, tap the
# Files tile, require files-ready (window over the shell), tap the
# first listing row (must open a file view: files-open kind=file),
# tap Back (files-back), screendump, tap Close (files-exit) and
# require intentd to reap the exit (intent-exit app=Files).
# usage: files-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-900}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-filesgate
LOG="$OUT/serial-files.log"
PPM="$OUT/files-screendump.ppm"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-files] %s\n' "$*"; }
fail() { printf '[ox-files] FAIL: %s\n' "$*" >&2; exit 1; }

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
print("[ox-files] tap injected at %s,%s" % (sys.argv[1], sys.argv[2]))
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
print("[ox-files] PIN digits + OK injected")
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
sleep 3

# 2. let the resourced memory drill settle
k=0
while [ $k -lt 300 ]; do
    grep -aq "name=resourced-tier-ok" "$LOG" 2>/dev/null && break
    grep -aq "name=resourced-tier-failed" "$LOG" 2>/dev/null && break
    sleep 2; k=$((k + 1))
done
say "resourced drill settled after $((k * 2))s"

# 3. PIN unlock (against the hashed verifier: /data/ox/lock.pin is a
#    salted, iterated SHA-256 record now — no plaintext on disk)
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
[ "$UNLOCKED" = yes ] || fail "no shell-unlocked milestone (hashed-PIN unlock failed)"
grep -aq "enrolled as salted hash" "$LOG" 2>/dev/null \
    && say "PIN verifier: salted-hash enrollment confirmed on first boot"
say "unlocked with PIN"

# 4. tap the Files tile (2nd tile, center 402,195) -> files-ready
attempt=0
READY=no
while [ $attempt -lt 3 ]; do
    qmp_tap 402 195
    k=0
    while [ $k -lt 30 ]; do
        grep -aq "name=files-ready" "$LOG" 2>/dev/null && { READY=yes; break; }
        sleep 2; k=$((k + 1))
    done
    [ "$READY" = yes ] && break
    attempt=$((attempt + 1))
    say "files-ready not observed (retry $((attempt + 1)))"
done
[ "$READY" = yes ] || fail "Files did not become ready through the intent chain"
say "Files launched and drew"
grep -a -e "name=shell-intent app=Files" -e "name=intent-start app=Files" -e "name=files-ready" "$LOG" | tail -3 | sed 's/^/[ox-files]   /'

# 5. tap the first listing row (window row 0 center = screen 640,242)
#    -> files-open kind=file
attempt=0
OPENED=no
while [ $attempt -lt 3 ]; do
    qmp_tap 640 242
    k=0
    while [ $k -lt 20 ]; do
        grep -aq "name=files-open.*kind=file" "$LOG" 2>/dev/null && { OPENED=yes; break; }
        sleep 2; k=$((k + 1))
    done
    [ "$OPENED" = yes ] && break
    attempt=$((attempt + 1))
    say "files-open not observed (retry $((attempt + 1)))"
done
[ "$OPENED" = yes ] || fail "tapping a listing row did not open a file view"
say "row tap opened a file view:"
grep -a "name=files-open" "$LOG" | tail -1 | sed 's/^/[ox-files]   /'

# 6. tap Back (window 123,632 -> screen 313,712) -> files-back
attempt=0
BACKED=no
while [ $attempt -lt 3 ]; do
    qmp_tap 313 712
    k=0
    while [ $k -lt 20 ]; do
        grep -aq "name=files-back" "$LOG" 2>/dev/null && { BACKED=yes; break; }
        sleep 2; k=$((k + 1))
    done
    [ "$BACKED" = yes ] && break
    attempt=$((attempt + 1))
    say "files-back not observed (retry $((attempt + 1)))"
done
[ "$BACKED" = yes ] || fail "Back tap did not return to the listing"
say "Back returned to the listing"

# 7. artifact: screendump of the listing state
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
print("[ox-files] screendump ok")
PYEOF

# 8. tap Close (window 777,632 -> screen 967,712) -> files-exit
attempt=0
EXITED=no
while [ $attempt -lt 3 ]; do
    qmp_tap 967 712
    k=0
    while [ $k -lt 20 ]; do
        grep -aq "name=files-exit" "$LOG" 2>/dev/null && { EXITED=yes; break; }
        sleep 2; k=$((k + 1))
    done
    [ "$EXITED" = yes ] && break
    attempt=$((attempt + 1))
    say "files-exit not observed (retry $((attempt + 1)))"
done
[ "$EXITED" = yes ] || fail "Close tap did not exit the app"

# 9. intentd must reap the exit
k=0
while [ $k -lt 30 ]; do
    grep -aq "intent-exit app=Files" "$LOG" 2>/dev/null && break
    sleep 2; k=$((k + 1))
done
grep -aq "intent-exit app=Files" "$LOG" 2>/dev/null || fail "intentd did not reap the Files exit"
say "intentd reaped the Files exit"

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — Files: launch, open, back, close, reap (on the hashed-PIN shell)"
echo "FILES GATE ALL GREEN"
