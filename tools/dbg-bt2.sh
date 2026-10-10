#!/bin/sh
L=/tmp/ox-btg/serial-bt.log
echo "--- bt: last kernel ts + suspend/resume evidence:"
grep -a 'pm-suspend-request\|Suspending console\|pm-resumed\|Restarting tasks\|rtc-pl031' "$L" | tail -5 | cut -c1-130
echo "--- bt: last kernel ts:"
grep -a '^\[' "$L" | tail -1 | cut -c1-45
echo
L2=/tmp/ox-wfg/serial-wifi.log
echo "--- wifi: module/iface evidence:"
grep -a 'hwsim\|wlan' "$L2" | head -6 | cut -c1-130
echo "--- wifi: last ts:"
grep -a '^\[' "$L2" | tail -1 | cut -c1-45
