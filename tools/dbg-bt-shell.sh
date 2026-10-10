#!/bin/sh
L=/tmp/ox-btg/serial-bt.log
echo "--- shell/lock milestones:"
grep -a 'name=shell\|lock\|OXMILESTONE name=inputd\|ox-shell' "$L" | tail -8 | cut -c1-140
echo "--- last 3 lines:"
tail -3 "$L" | cut -c1-130
echo "--- compositor/display errors:"
grep -ac 'compositor render failed\|No such file' "$L"
