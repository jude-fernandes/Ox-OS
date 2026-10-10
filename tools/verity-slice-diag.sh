#!/bin/sh
# diagnostic v2: byte-exact slice verify of the flashed slot-a layout
set -eu
W=/tmp/ox-verityslice
IMG=/nix/store/5py7rvg7yvx5h8n86jyd779r8sy83q4l-image-pinephone-pro-0.1.0-chunk72
FLASH=/tmp/ox-slotboot-debug/flash.img
rm -rf "$W"; mkdir -p "$W"
# data: 25894 x 4096 = 106061824 bytes at partition offset 0 (abs 144MiB)
dd if="$FLASH" of="$W/sysa.img" bs=4096 skip=$((144*256)) count=25894 status=none
# tree: exactly 843776 bytes at partition offset 2944MiB (abs 3088MiB)
dd if="$FLASH" of="$W/tree.img" bs=1M iflag=skip_bytes,count_bytes \
    skip=$((3088*1048576)) count=843776 status=none
echo "sizes:"; wc -c < "$W/sysa.img"; wc -c < "$W/tree.img"
veritysetup verify --no-superblock --data-blocks 25894 \
    --salt=10b14701c6d25daf5706c7cd630226514cc904bd0780cb2a8b9d7368a4425efb \
    "$W/sysa.img" "$W/tree.img" \
    92c438f22d40df5ff2d813b780bc9caad0ea98df74db481e3daa4a2b38a615d2 \
    && echo "SLICE-V2 PASS: flashed slot-a layout is self-consistent" \
    || echo "SLICE-V2 FAIL: flashed layout inconsistent"
