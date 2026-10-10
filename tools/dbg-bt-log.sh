#!/bin/sh
L=/tmp/ox-btg/serial-bt.log
echo "size=$(wc -c < "$L")"
grep -a 'pm-suspend-request\|Suspending console\|pm-resumed\|Freezing remaining' "$L" | tail -4 | cut -c1-110
grep -a '^\[' "$L" | tail -1 | cut -c1-45
