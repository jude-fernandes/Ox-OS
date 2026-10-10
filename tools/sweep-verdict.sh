#!/bin/sh
# Print the overnight chain verdict: wifi runs + every sweep gate
# PASS/FAIL in order, plus the final ALL GREEN / HAD FAILURES line.
# Usage (host): wsl -u root bash -c "sh /root/oxbuild/tools/sweep-verdict.sh"
L=/root/oxbuild/queue/status
F=$(ls -t "$L" | head -1)
echo "== chain log: $L/$F"
grep -a '=== NIGHT\|=== SWEEP\|^PASS \|^FAIL \|PHASE4 SWEEP' "$L/$F"
echo "== per-gate anomalies (gate logs with errors, if any):"
for g in /tmp/sweep-*.log; do
    if grep -aq 'FAIL' "$g" 2>/dev/null; then
        echo "-- $g"; grep -a 'FAIL' "$g" | head -3
    fi
done
