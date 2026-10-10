#!/bin/sh
# Diagnostic: boot the payload with virtio-gpu QEMU tracing, wait for the
# compositor milestone, screendump, then report both sides of the flip
# (guest oxcom kmsg/stderr lines + host-side QEMU virtio_gpu trace).
# usage: gfx-trace-diag.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-200}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$PAYLOAD/serial-trace.log"
TRACE=/tmp/ox-trace.txt
rm -f "$LOG" "$TRACE" /tmp/ox-qmp

(OX_GFX=1 OX_QEMU_EXTRA="-trace enable=virtio_gpu_cmd_set_scanout -trace enable=virtio_gpu_cmd_res_flush -trace enable=virtio_gpu_cmd_res_xfer_toh_2d -trace enable=virtio_gpu_cmd_res_create_2d -D /tmp/ox-qtrace.log" \
    timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

i=0
while [ $i -lt 220 ]; do
    grep -q "name=compositor-rendered" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -q "name=compositor-rendered" "$LOG" || {
    tail -5 "$LOG"; pkill -f qemu-system-aarch64 || true; echo "DIAG: no flip"; exit 1; }
sleep 2
pkill -f qemu-system-aarch64 || true
sleep 1

echo "=== guest side (oxcom) ==="
grep "oxcom:" "$LOG" || true
echo "=== host side (QEMU virtio_gpu trace, tail) ==="
tail -30 /tmp/ox-qtrace.log 2>/dev/null | grep virtio_gpu || echo "no trace events"
echo "=== trace event summary ==="
if [ -f /tmp/ox-qtrace.log ]; then
    grep -o "virtio_gpu_[a-z_0-9]*" /tmp/ox-qtrace.log | sort | uniq -c | sort -rn
fi
