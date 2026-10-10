#!/bin/sh
# Phase-4 sweep RETRY: the 8 gates that failed during the loaded
# sweep run. Adds what the sweep lacked: python emulator cleanup and
# a settle pause between gates (the sweep's middle window degraded
# the host — suspend-resume froze, taps missed — while every one of
# these gates passed its own dedicated run).
set -u
cd /root/oxbuild
GATES="bt-gate wifi-gate camera-app-gate dialer-app-gate sms-app-gate tiles-gate grid-event-gate uninstall-gate"
pass=""
fail=""
for g in $GATES; do
    pkill -f '[q]emu-system-aarch64' >/dev/null 2>&1 || true
    pkill -f 'modem-emu.py' >/dev/null 2>&1 || true
    pkill -f 'gnss-emu.py' >/dev/null 2>&1 || true
    pkill -f 'nfc-emu.py' >/dev/null 2>&1 || true
    sleep 5
    echo "=== RETRY $g $(date -u +%H:%M:%S)"
    if bash "tools/$g-run.sh" > "/tmp/retry-$g.log" 2>&1; then
        echo "PASS $g"
        pass="$pass $g"
    else
        echo "FAIL $g (log: /tmp/retry-$g.log)"
        fail="$fail $g"
    fi
done
pkill -f '[q]emu-system-aarch64' >/dev/null 2>&1 || true
echo "RETRY PASS:$pass"
echo "RETRY FAIL:${fail:- none}"
if [ -z "$fail" ]; then
    echo "PHASE4 RETRY ALL GREEN"
else
    echo "PHASE4 RETRY HAD FAILURES"
fi
