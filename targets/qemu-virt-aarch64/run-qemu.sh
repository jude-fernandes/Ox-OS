#!/bin/sh
# Launch the Phase-1 virtual target (QEMU virt-aarch64) from a built payload dir.
# usage: run-qemu.sh PAYLOAD_DIR KERNEL_IMAGE [LOGFILE]
set -eu
[ $# -ge 2 ] || { echo "usage: $0 PAYLOAD_DIR KERNEL [LOG]" >&2; exit 2; }
PAYLOAD="$1"; KERNEL="$2"; LOG="${3:-/dev/stdout}"

command -v qemu-system-aarch64 >/dev/null 2>&1 || {
    echo "ERROR: qemu-system-aarch64 not found (run on a Linux host with QEMU)" >&2
    exit 3; }
[ -f "$PAYLOAD/system.img" ] || { echo "missing $PAYLOAD/system.img" >&2; exit 4; }
[ -f "$PAYLOAD/system.hash.img" ] || { echo "missing verity hash image" >&2; exit 4; }

DATA_IMG="$PAYLOAD/data.img"
[ -f "$DATA_IMG" ] || dd if=/dev/zero of="$DATA_IMG" bs=1M count=256

# Data volume signature policy: LUKS (the designed path) and plain ext4
# payloads boot as they are; a blank image gets LUKS2-formatted with the
# payload's dev key (risk R-22) when available, ext4 otherwise.
LUKSIG="$(dd if="$DATA_IMG" bs=1 count=6 2>/dev/null | od -An -tx1 | tr -d ' \n')"
EXTSIG="$(dd if="$DATA_IMG" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')"
if [ "$LUKSIG" != "4c554b53babe" ] && [ "$EXTSIG" != "53ef" ]; then
    if [ -f "$PAYLOAD/data.img.key" ] && command -v cryptsetup >/dev/null 2>&1; then
        cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 \
            --pbkdf-force-iterations 10000 --batch-mode \
            --key-file "$PAYLOAD/data.img.key" "$DATA_IMG"
    else
        command -v mkfs.ext4 >/dev/null 2>&1 || {
            echo "ERROR: cryptsetup or mkfs.ext4 needed to format $DATA_IMG" >&2
            exit 5; }
        mkfs.ext4 -q -F "$DATA_IMG"
    fi
fi

INITRD_ARGS=""
[ -f "$PAYLOAD/initramfs.img" ] && INITRD_ARGS="-initrd $PAYLOAD/initramfs.img"

DISPLAY_ARGS="-nographic"
if [ "${OX_GFX:-0}" = "1" ]; then
    # virtio-gpu with framebuffer console; VNC server + QMP for screendumps
    DISPLAY_ARGS="-display ${OX_DISPLAY:-none} -serial mon:stdio \
        -device virtio-gpu-pci \
        -device virtio-keyboard-pci \
        -device virtio-tablet-pci \
        -vnc 127.0.0.1:${OX_VNC_DISPLAY:-1} \
        -qmp unix:/tmp/ox-qmp,server,nowait"
fi

# stdbuf -oL: stdout here is a PIPE, so glibc full-buffers QEMU's
# serial output at 4KB — in quiet console periods a milestone can sit
# in that buffer for MINUTES after the guest printed it, and gates
# polling the serial file race a stale view. Line buffering makes each
# guest line hit the log as it is printed.
exec stdbuf -oL qemu-system-aarch64 \
    -machine virt,highmem=off -cpu cortex-a57 -smp 1 -m 1024 \
    $DISPLAY_ARGS \
    ${OX_QEMU_EXTRA:-} \
    -monitor unix:/tmp/ox-qmon,server,nowait \
    -kernel "$KERNEL" $INITRD_ARGS \
    -append "$(cat "$PAYLOAD/cmdline.txt")${OX_KERNEL_EXTRA:-}" \
    -drive if=none,file="$DATA_IMG",format=raw,id=hd2 \
    -device virtio-blk-device,drive=hd2 \
    -drive if=none,file="$PAYLOAD/system.hash.img",format=raw,id=hd1 \
    -device virtio-blk-device,drive=hd1 \
    -drive if=none,file="$PAYLOAD/system.img",format=raw,id=hd0 \
    -device virtio-blk-device,drive=hd0 2>&1 | tee "$LOG"
