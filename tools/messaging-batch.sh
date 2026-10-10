#!/bin/sh
# Messaging chunk batch: build once, run the messaging-app gate, then
# re-prove the three dynamic-tile gates (tiles, grid-event, uninstall)
# on the same payload — the rootfs now stages one more signed package,
# and the tile taps depend on the sorted dynamic grid.
set -u
cd /root/oxbuild
# a failed gate leaves its QEMU running (fail() exits without cleanup)
# — two emulated machines on this box blow the boot-time windows
pkill -f '[q]emu-system-aarch64' >/dev/null 2>&1 || true
sleep 1
if bash tools/sms-app-gate-run.sh; then
    echo "BATCH: sms-app-gate GREEN"
else
    echo "BATCH: sms-app-gate FAILED"
    exit 1
fi
P=/tmp/ox-smsgate-payload
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
