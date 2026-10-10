#!/bin/sh
L=/tmp/ox-uninstgate/serial-uninst.log
echo "--- oxcom render failures:"
grep -ac 'compositor render failed' "$L"
echo "--- shell locked / unlocked milestones:"
grep -a 'name=shell-locked\|name=shell-unlocked\|name=intent-install' "$L" | tail -5 | cut -c1-110
echo "--- ox-shell alive lines:"
grep -ac 'ox-shell' "$L"
echo "--- tail:"
tail -3 "$L" | cut -c1-120
