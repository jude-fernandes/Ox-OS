#!/bin/sh
# ground truth: let veritysetup itself build the dm table over slices and
# print the kernel's view of it. data = p3 (144MiB), hash = the tree at
# device 3088MiB (= p3 + 2944MiB)
set -eu
IMG=/tmp/ox-slotboot-debug/flash.img
PPP=$(ls -dt /nix/store/*image-pinephone-pro-0.1.0-chunk72 2>/dev/null | grep -v drv | head -1)
. "$PPP/digest.env"
LOD2=$(losetup --find --show --offset $((144 * 1048576)) --sizelimit $((3072 * 1048576)) "$IMG")
LOH=$(losetup --find --show --offset $((3088 * 1048576)) --sizelimit 843776 "$IMG")
echo "data=$LOD2 hash=$LOH"
veritysetup create oxtest "$LOD2" "$LOH" "$OX_ROOT_HASH" 2>&1 | head -3 || true
DMN=$(ls /sys/block | grep oxtest | head -1) || true
echo "table for $DMN:"
cat /sys/block/$DMN/dm/table 2>/dev/null || true
veritysetup remove oxtest 2>/dev/null || true
losetup -d "$LOD2" "$LOH" 2>/dev/null || true
