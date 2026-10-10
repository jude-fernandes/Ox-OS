#!/bin/sh
# Debug: wifi gate serial log — hwsim/wlan evidence.
L=/tmp/ox-wfg/serial-wifi.log
if [ ! -f "$L" ]; then
    echo "LOG MISSING"
    exit 0
fi
echo "size=$(wc -c < "$L")"
echo "--- hwsim/wlan/cfg80211 lines:"
grep -a 'hwsim\|wlan\|cfg80211\|mac80211\|usbcore' "$L" | head -14 | cut -c1-140
echo "--- wifi-failed count: $(grep -ac 'wifi-failed' "$L")"
echo "--- last lines:"
tail -3 "$L" | cut -c1-130
