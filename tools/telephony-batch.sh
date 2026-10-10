#!/bin/sh
# Telephony chunk batch: build once, run the dialer gate, then re-prove
# the three dynamic-tile gates whose tap coordinates moved with the
# 4-slot dynamic grid (tiles, grid-event, uninstall) on the same payload.
set -u
cd /root/oxbuild
# a failed gate leaves its QEMU running (fail() exits without cleanup)
# — two emulated machines on this box blow the boot-time windows
pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
if bash tools/dialer-app-gate-run.sh; then
    echo "BATCH: dialer-app-gate GREEN"
else
    echo "BATCH: dialer-app-gate FAILED"
    exit 1
fi
P=/tmp/ox-dialgate-payload
K="$(sed -n 2p /tmp/nixout.txt)/Image"
for g in tiles-gate grid-event-gate uninstall-gate; do
    if bash "tools/$g.sh" "$P" "$K"; then
        echo "BATCH: $g GREEN"
    else
        echo "BATCH: $g FAILED"
        exit 1
    fi
done
echo "BATCH: ALL FOUR GATES GREEN"
