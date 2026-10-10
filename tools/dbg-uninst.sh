#!/bin/sh
L=/tmp/ox-uninstgate/serial-uninstall.log
echo "size=$(wc -c < "$L")"
echo "--- pm/oxcom/shell/intent evidence:"
grep -a 'pm-drill-skipped\|pm-resumed\|pm-selftest\|oxcom\|ox-shell\|intent-install app=Hello\|pkg-flow' "$L" | tail -12 | cut -c1-130
echo "--- last ts:"
grep -a '^\[' "$L" | tail -1 | cut -c1-45
