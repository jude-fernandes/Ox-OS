#!/bin/sh
# Round 2 of the Phase-4 close-out: the 9 gates that failed sweep6,
# with x3-scaled budgets and tap_retry, on an idle host.
set -u
cd /root/oxbuild
GATES="camera-app-gate dialer-app-gate mt-call-gate sms-app-gate sms-recv-gate nfc-gate tiles-gate grid-event-gate uninstall-gate"
pass=""
fail=""
for g in $GATES; do
    pkill -f '[q]emu-system-aarch64' >/dev/null 2>&1 || true
    pkill -f '[e]mu.py' >/dev/null 2>&1 || true
    sleep 3
    echo "=== ROUND2 $g $(date -u +%H:%M:%S)"
    if bash "tools/$g-run.sh" > "/tmp/round2-$g.log" 2>&1; then
        echo "PASS $g"
        pass="$pass $g"
    else
        echo "FAIL $g (log: /tmp/round2-$g.log)"
        fail="$fail $g"
    fi
done
pkill -f '[q]emu-system-aarch64' >/dev/null 2>&1 || true
echo "ROUND2 PASS:$pass"
echo "ROUND2 FAIL:${fail:- none}"
if [ -z "$fail" ]; then
    echo "PHASE4 ROUND2 ALL GREEN"
else
    echo "PHASE4 ROUND2 HAD FAILURES"
fi
