#!/bin/sh
# Boot the virtual target under QEMU, wait for milestones, print report.
# usage: boot-test.sh PAYLOAD_DIR KERNEL_IMAGE [TIMEOUT_S]
set -u
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-420}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$PAYLOAD/serial.log"
# NOTE: keep $PAYLOAD/data.img — it is a formatted LUKS2 volume (mkdata.sh);
# run-qemu.sh creates a fresh zeroed one only when absent.
rm -f "$LOG"

(timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

i=0
while [ $i -lt 240 ]; do
    if grep -q "name=userspace-ready" "$LOG" 2>/dev/null; then
        break
    fi
    sleep 2
    i=$((i + 1))
done

if ! grep -q "name=userspace-ready" "$LOG" 2>/dev/null; then
    echo "BOOT-TEST FAIL: no userspace-ready within ${TMO}s; last lines:"
    tail -20 "$LOG" 2>/dev/null
    pkill -f qemu-system-aarch64 2>/dev/null
    exit 1
fi

sleep 2
pkill -f qemu-system-aarch64 2>/dev/null
echo "--- milestones ---"
grep OXMILESTONE "$LOG"
python3 "$OXDIR/tools/boottime-parse.py" "$LOG"
