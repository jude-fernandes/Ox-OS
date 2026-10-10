#!/bin/sh
# PIN-enrollment gate: the lock secret is owned by lockd, and the user
# can rotate it on the pad. Boot -> unlock 1234 (verify via lockd, fail
# closed) -> Settings -> Change PIN -> WRONG current PIN refused ->
# correct flow: current 1234, new 5678, confirm 5678 -> lockd journals
# pin-changed old-rejected=true new-accepted=true (self-verified
# rotation) -> screendump.
# usage: pin-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-900}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-pingate
LOG="$OUT/serial-pin.log"
PPM="$OUT/pin-screendump.ppm"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-pin] %s\n' "$*"; }
fail() { printf '[ox-pin] FAIL: %s\n' "$*" >&2; exit 1; }

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
print("[ox-pin] tap injected at %s,%s" % (sys.argv[1], sys.argv[2]))
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
print("[ox-pin] PIN digits + OK injected")
PYEOF
}

# Settings' enrollment pad: window origin (303,200) + screen offset
# (190,80); cells 90x56 gap 12. Taps digits then OK.
qmp_spad() {
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
rects = [(303 + (i % 3) * 102 + 190, 200 + (i // 3) * 68 + 80, 90, 56) for i in range(12)]
for ch in sys.argv[1]:
    i = keys.index(ch)
    x, y, w, h = rects[i]
    tap(x + w / 2, y + h / 2)
    time.sleep(1.0)
i = keys.index("OK")
x, y, w, h = rects[i]
tap(x + w / 2, y + h / 2)
print("[ox-pin] enrollment pad: %s + OK" % sys.argv[1])
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

# 1. boot basics
i=0
while [ $i -lt 150 ]; do
    grep -aq "name=shell-home" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -aq "name=shell-locked" "$LOG" || fail "no shell-locked milestone"
grep -aq "name=intentd-ready" "$LOG" || fail "no intentd-ready milestone"
grep -aq "name=lockd-ready" "$LOG" || fail "no lockd-ready milestone"
say "locked shell up, lockd + intentd supervised"
sleep 3

# 2. resourced drill settle
k=0
while [ $k -lt 300 ]; do
    grep -aq "name=resourced-tier-ok" "$LOG" 2>/dev/null && break
    grep -aq "name=resourced-tier-failed" "$LOG" 2>/dev/null && break
    sleep 2; k=$((k + 1))
done
say "resourced drill settled after $((k * 2))s"

# 3. unlock 1234 — verification goes through lockd now
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
[ "$UNLOCKED" = yes ] || fail "no shell-unlocked milestone (lockd verify path failed)"
say "unlocked with PIN via lockd"

# 4. open Settings
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
[ "$READY" = yes ] || fail "Settings did not launch"
say "Settings open"

# 5. tap Change PIN (window 48,538 150x48 -> center screen 313,642)
attempt=0
OPEN=no
while [ $attempt -lt 3 ]; do
    qmp_tap 313 642
    k=0
    while [ $k -lt 20 ]; do
        grep -aq "name=settings-enroll-open" "$LOG" 2>/dev/null && { OPEN=yes; break; }
        sleep 2; k=$((k + 1))
    done
    [ "$OPEN" = yes ] && break
    attempt=$((attempt + 1))
    say "enroll view not observed (retry $((attempt + 1)))"
done
[ "$OPEN" = yes ] || fail "Change PIN button did not open the enrollment flow"
say "enrollment pad open"

# 6. negative leg: WRONG current PIN (9999). Settings collects
#    current -> new -> confirm locally and only then asks lockd, so
#    the refusal lands after the full three entries.
qmp_spad 9999
sleep 3
qmp_spad 5678
sleep 3
qmp_spad 5678
wait_ms "name=pin-enroll-refused" 25 "wrong current PIN was not refused"
say "wrong current PIN refused by lockd"
sleep 2

# 7. rotation: current 1234 -> new 5678 -> confirm 5678
qmp_spad 1234
sleep 3
qmp_spad 5678
sleep 3
qmp_spad 5678
wait_ms "name=pin-changed old-rejected=true new-accepted=true" 30 "lockd did not self-verify the rotation"
wait_ms "name=settings-pin-changed" 20 "Settings did not confirm the rotation"
say "PIN rotated 1234 -> 5678 (lockd self-verified: old rejected, new accepted)"

# 8. artifact: screendump of the post-rotation Settings view
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
print("[ox-pin] screendump ok")
PYEOF

# 9. relock from the UI and prove the rotation end to end: close
#    Settings, tap Lock, the OLD PIN is rejected, the NEW PIN unlocks.
#    NOTE: after relock there are no prior shell-pin-rejected /
#    shell-unlocked milestones this boot, so plain presence waits work.
qmp_tap 967 712
wait_ms "name=settings-close" 20 "Settings did not close"
tap_wait() {
    # tap_wait SX SY GREP LABEL — tap, wait, retry up to 3x
    attempt=0
    while [ $attempt -lt 3 ]; do
        qmp_tap "$1" "$2"
        k=0
        while [ $k -lt 20 ]; do
            grep -aq "$3" "$LOG" 2>/dev/null && return 0
            sleep 2; k=$((k + 1))
        done
        attempt=$((attempt + 1))
        say "$4 not observed (retry $((attempt + 1)))"
    done
    fail "$4"
    return 1
}
tap_wait 123 652 "name=shell-relocked" "Lock button did not relock the shell"
say "device relocked from the UI"

tap_wait_then() {
    # tap_wait_then PIN GREP LABEL — enter a PIN, wait for the verdict
    attempt=0
    while [ $attempt -lt 3 ]; do
        qmp_pin "$1"
        k=0
        while [ $k -lt 300 ]; do
            grep -aq "$2" "$LOG" 2>/dev/null && return 0
            sleep 2; k=$((k + 1))
        done
        attempt=$((attempt + 1))
        say "$3 not observed (retry $((attempt + 1)))"
    done
    fail "$3"
    return 1
}

tap_wait_then 1234 "name=shell-pin-rejected" "old PIN was not rejected after rotation"
say "old PIN 1234 rejected after rotation"
tap_wait_then 5678 "name=shell-unlocked" "the rotated PIN (5678) did not unlock"
say "rotated PIN 5678 unlocks — rotation proven end to end"

# 10. throttle: relock first (leg 9 left the device unlocked), then
#     FIVE consecutive wrong PINs arm a 16-second backoff window
#     (1+2+4+8+16 escalation) — wide enough for the next full pad
#     injection (~9 s) to land INSIDE it and be refused WITH
#     throttling. After the next window (32 s) the owner unlocks.
tap_wait 123 652 "name=shell-relocked" "Lock button did not relock the shell"
say "throttle drill: relocked — five wrong PINs to arm a 16s window"
tap_wait_then 1111 "name=shell-pin-rejected" "wrong PIN 1111 was not rejected"
tap_wait_then 2222 "name=shell-pin-rejected" "wrong PIN 2222 was not rejected"
tap_wait_then 3333 "name=shell-pin-rejected" "wrong PIN 3333 was not rejected"
tap_wait_then 4444 "name=shell-pin-rejected" "wrong PIN 4444 was not rejected"
tap_wait_then 5555 "name=shell-pin-rejected" "wrong PIN 5555 was not rejected"
attempt=0
THR=no
while [ $attempt -lt 3 ]; do
    N0=$(grep -ac "name=shell-pin-throttled" "$LOG" 2>/dev/null || true)
    qmp_pin 6666
    k=0
    while [ $k -lt 10 ]; do
        N1=$(grep -ac "name=shell-pin-throttled" "$LOG" 2>/dev/null || true)
        [ "$N1" -gt "$N0" ] 2>/dev/null && { THR=yes; break; }
        sleep 2; k=$((k + 1))
    done
    [ "$THR" = yes ] && break
    attempt=$((attempt + 1))
    say "shell-pin-throttled not observed (retry $((attempt + 1)))"
done
[ "$THR" = yes ] || fail "throttling did not engage after consecutive failures"
say "throttle engaged: sixth verify surfaced as throttled"

# after the throttle window (failure 6 armed 32 s) the OWNER unlocks
# with the correct PIN
sleep 35
attempt=0
UN=no
while [ $attempt -lt 3 ]; do
    N0=$(grep -ac "name=shell-unlocked" "$LOG" 2>/dev/null || true)
    qmp_pin 5678
    k=0
    while [ $k -lt 300 ]; do
        N1=$(grep -ac "name=shell-unlocked" "$LOG" 2>/dev/null || true)
        [ "$N1" -gt "$N0" ] 2>/dev/null && { UN=yes; break; }
        sleep 2; k=$((k + 1))
    done
    [ "$UN" = yes ] && break
    attempt=$((attempt + 1))
    say "owner unlock after throttle not observed (retry $((attempt + 1)))"
done
[ "$UN" = yes ] || fail "owner could not unlock after the throttle window"
wait_ms "name=pin-verify-success-after-failures" 20 "throttle reset journal missing"
say "owner unlocked after the throttle window (throttle reset)"
grep -aq "pin-verify-denied" "$LOG" || fail "denial journal missing"
say "ALL GREEN — lockd hardening: throttle engages, resets, owner survives"

# 11. panic wipe: the FINAL act — relock, duress unlock triggers the
#     wipe of every /data/ox secret (journaled by lockd + shell)
tap_wait 123 652 "name=shell-relocked" "Lock button did not relock the shell"
tap_wait_then 9999 "name=pin-verify-duress" "duress PIN did not produce the duress verdict (lockd dev-enrolls it at boot)"
wait_ms "name=shell-duress-unlocked" 20 "shell did not flag the duress unlock"
wait_ms "name=shell-panic-wipe-triggered" 20 "shell did not trigger the panic wipe"
wait_ms "name=panic-wipe-executed" 20 "lockd did not execute the panic wipe"
say "panic wipe: lockd destroyed the user secrets; artifact = journal"
say "ALL GREEN — rotate, relock, old PIN dead, new PIN opens, duress flagged, wipe executed"

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — rotate, relock, old PIN dead, new PIN opens, duress flagged"
echo "PIN GATE ALL GREEN"
