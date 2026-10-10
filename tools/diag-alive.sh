#!/bin/sh
# Is QEMU alive-but-stalled, or dead? Writes guest log directly (no tee).
set -u
PAYLOAD="$1"; KERNEL="$2"
rm -f "$PAYLOAD/s.log"
[ -f "$PAYLOAD/data.img" ] || dd if=/dev/zero of="$PAYLOAD/data.img" bs=1M count=256

qemu-system-aarch64 \
    -machine virt -cpu cortex-a57 -smp 1 -m 2048 \
    -nographic -monitor none \
    -kernel "$KERNEL" \
    -initrd "$PAYLOAD/initramfs.img" \
    -append "$(cat "$PAYLOAD/cmdline.txt")" \
    -drive if=none,file="$PAYLOAD/data.img",format=raw,id=hd2 \
    -device virtio-blk-device,drive=hd2 \
    -drive if=none,file="$PAYLOAD/system.hash.img",format=raw,id=hd1 \
    -device virtio-blk-device,drive=hd1 \
    -drive if=none,file="$PAYLOAD/system.img",format=raw,id=hd0 \
    -device virtio-blk-device,drive=hd0 >"$PAYLOAD/s.log" 2>&1 &
QPID=$!

sleep 75
if kill -0 "$QPID" 2>/dev/null; then
    echo "QEMU ALIVE after 75s; log lines: $(wc -l <"$PAYLOAD/s.log")"
else
    wait "$QPID"
    echo "QEMU EXITED code=$?; log lines: $(wc -l <"$PAYLOAD/s.log")"
fi
tail -5 "$PAYLOAD/s.log"
kill "$QPID" 2>/dev/null || true
