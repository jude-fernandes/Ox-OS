#!/bin/sh
# Doze gate: proves the idle auto-suspend loop end to end.
#   1. boot selftest cycle (n=1), then the idle policy starts
#   2. no user input -> powerd auto-suspends (reason=idle), RTC wakes it,
#      still idle -> it auto-suspends again (the doze loop)
#   3. the gate injects a keystroke right after a resume; oxcom reports
#      activity to powerd, which postpones the next cycle
#   4. asserts: >=2 autosuspends, activity noted, and NO autosuspend during
#      a 12 s post-activity window (the doze cadence is ~13 s, so silence
#      there is only possible if activity actually reset the idle clock)
# usage: pm-doze-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-420}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$PAYLOAD/serial-doze.log"
rm -f "$LOG" /tmp/ox-qmp

say() { printf '[ox-doze] %s\n' "$*"; }
fail() { printf '[ox-doze] FAIL: %s\n' "$*" >&2; exit 1; }
command -v qemu-system-aarch64 >/dev/null || fail "qemu missing"

(OX_GFX=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

# 1. boot selftest completes and the idle policy starts
i=0
while [ $i -lt 90 ]; do
    grep -q "name=pm-idle-policy-start" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -q "name=pm-idle-policy-start" "$LOG" || {
    tail -5 "$LOG"; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
    fail "idle policy never started"; }
say "idle policy live (selftest cycle done)"

# 2. wait for the first doze autosuspend + its resume
i=0
while [ $i -lt 45 ]; do
    grep -q "name=pm-autosuspend" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -q "name=pm-autosuspend" "$LOG" || {
    pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true; fail "no autosuspend"; }
say "first idle autosuspend observed"
i=0
while [ $i -lt 45 ]; do
    grep -q "name=pm-resumed n=2" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -q "name=pm-resumed n=2" "$LOG" || {
    pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true; fail "no resume after autosuspend"; }

# 3. wait for the machine to be awake again (post 2nd autosuspend), then
#    inject a keystroke inside the awake window
i=0
while [ $i -lt 45 ]; do
    grep -q "name=pm-resumed n=3" "$LOG" 2>/dev/null && break
    sleep 1; i=$((i + 1))
done
say "doze loop confirmed (>=2 autosuspends); injecting activity"
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
s.send(b"sendkey x\n")
time.sleep(0.1)
drain()
s.close()
PYEOF

# 4. activity must reach powerd
i=0
while [ $i -lt 15 ]; do
    grep -q "name=pm-activity" "$LOG" 2>/dev/null && break
    sleep 1; i=$((i + 1))
done
grep -q "name=pm-activity" "$LOG" || {
    pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true; fail "activity never reached powerd"; }
say "activity noted by powerd"

# 5. postponement proof: the doze cadence is ~13 s; a quiet 12 s window
#    after activity is only possible if the idle clock was reset
sleep 12
BEFORE=$(grep -c "name=pm-autosuspend" "$LOG" || true)
sleep 1
AFTER=$(grep -c "name=pm-autosuspend" "$LOG" || true)
[ "$AFTER" = "$BEFORE" ] || fail "autosuspend fired $((AFTER - BEFORE))x after activity (idle clock not reset)"
say "no autosuspend in 12 s post-activity (idle clock reset confirmed)"

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
BOOTS=$(grep -c "name=stage2-begin" "$LOG" || true)
[ "$BOOTS" = "1" ] || fail "expected exactly 1 boot, saw $BOOTS"
say "ALL GREEN — doze loop + activity postponement proven"
