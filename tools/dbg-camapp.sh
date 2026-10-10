#!/bin/sh
L=/tmp/ox-camappgate/serial-camapp.log
echo "size=$(wc -c < "$L")"
echo "--- launch/ready events:"
grep -a 'camera-app-ready\|intent-start\|launch' "$L" | tail -6 | cut -c1-150
echo "--- consults/streaming:"
grep -a 'camera-consult\|camera-streaming-on\|camera-viewfinder' "$L" | tail -4 | cut -c1-130
echo "--- last kernel ts + last lines:"
grep -a '^\[' "$L" | tail -1 | cut -c1-45
tail -2 "$L" | cut -c1-130
