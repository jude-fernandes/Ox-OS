#!/bin/sh
# Live-kernel check: open the verity pair via device-mapper and read a file.
set -eu
P="/tmp/ox-boot/payload"
cd "$P"
. "$P/digest.env"

command -v veritysetup >/dev/null || { echo "need cryptsetup-bin" >&2; exit 2; }

LOOP_DATA=$(losetup --find --show "$P/system.img")
LOOP_HASH=$(losetup --find --show "$P/system.hash.img")
echo "loops: $LOOP_DATA $LOOP_HASH"

cleanup() {
    veritysetup close oxtest 2>/dev/null || true
    losetup -d "$LOOP_DATA" "$LOOP_HASH" 2>/dev/null || true
}
trap cleanup EXIT

veritysetup open --no-superblock --salt="$OX_SALT" \
    "$LOOP_DATA" oxtest "$LOOP_HASH" "$OX_ROOT_HASH" || {
    echo "OPEN_FAILED"; exit 1; }

mkdir -p /mnt/oxtest
if mount -o ro /dev/mapper/oxtest /mnt/oxtest 2>/dev/null; then
    ls /mnt/oxtest/sbin/ >/dev/null && echo LIVE_KERNEL_OK
    umount /mnt/oxtest
else
    echo "MOUNT_FAILED (but open succeeded)"
fi
