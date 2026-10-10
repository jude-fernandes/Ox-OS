#!/bin/sh
L=/tmp/ox-btg/serial-bt.log
echo "--- rtc/clock lines in bt boot:"
grep -a 'rtc\|hctosys\|clocksource\|Set system clock\|setting system clock' "$L" | head -8 | cut -c1-140
echo "--- pl031 presence:"
grep -ac 'pl031' "$L"
