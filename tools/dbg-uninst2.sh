#!/bin/sh
L=/tmp/ox-uninstgate/serial-uninst.log
echo "size=$(wc -c < "$L")"
grep -a 'pm-drill-skipped\|pm-selftest-begin\|pm-resumed\|intent-install app=Hello\|oxcom\|ox-shell' "$L" | tail -8 | cut -c1-130
echo "--- last ts:"
grep -a '^\[' "$L" | tail -1 | cut -c1-45
