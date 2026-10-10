#!/bin/sh
# Power gate: boot with the powerd boot self-test enabled, watch one real
# suspend/resume cycle, and prove the system RESUMED instead of rebooted
# (exactly one stage2-begin in the whole log). The RTC wakealarm is armed
# by powerd; if the virtual RTC cannot wake the machine, the gate presses
# the power button via QMP system-wakeup after 20 s.
# usage: pm-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-420}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$PAYLOAD/serial-pm.log"
rm -f "$LOG" /tmp/ox-qmp

say() { printf '[ox-pm] %s\n' "$*"; }
fail() { printf '[ox-pm] FAIL: %s\n' "$*" >&2; exit 1; }
command -v qemu-system-aarch64 >/dev/null || fail "qemu missing"

(OX_GFX=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

# 1. wait for the self-test to enter suspend
i=0
while [ $i -lt 90 ]; do
    grep -q "name=pm-selftest-begin" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -q "name=pm-selftest-begin" "$LOG" || {
    tail -5 "$LOG"; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
    fail "self-test never started"; }
say "self-test started; suspend requested (8 s RTC alarm armed)"

# 2. wait for resume; if nothing wakes the machine in 20 s, press power
i=0
while [ $i -lt 10 ]; do
    grep -q "name=pm-resumed" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
if ! grep -q "name=pm-resumed" "$LOG" 2>/dev/null; then
    say "RTC wake did not fire; pressing power button (QMP system-wakeup)"
    python3 - <<'PYEOF'
import json, socket

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
r = send({"execute": "system-wakeup"})
print("wakeup:", r)
PYEOF
    j=0
    while [ $j -lt 30 ]; do
        grep -q "name=pm-resumed" "$LOG" 2>/dev/null && break
        sleep 2; j=$((j + 1))
    done
fi
grep -q "name=pm-resumed" "$LOG" || {
    pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
    fail "no resume (neither RTC wake nor system-wakeup)"; }
say "resumed from suspend"

sleep 2
pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1

# 3. prove RESUME, not REBOOT: exactly one stage2-begin; boot must not restart
BOOTS=$(grep -c "name=stage2-begin" "$LOG" || true)
[ "$BOOTS" = "1" ] || fail "expected exactly 1 boot, saw $BOOTS (that's a reboot, not a resume)"
say "single boot confirmed (resume, not reboot)"

# 4. services survived: oxcom claimed the scanout once and still holds it
SERVES=$(grep -c "oxcom: serving on" "$LOG" || true)
[ "$SERVES" = "1" ] || fail "oxcom restarted across resume ($SERVES serving lines)"
say "compositor survived the cycle"

# 5. sanity: suspend counter accounted
grep -q "name=pm-resumed n=1" "$LOG" && say "resume counter accounted (n=1)"

say "ALL GREEN — suspend -> resume cycle proven with services intact"
