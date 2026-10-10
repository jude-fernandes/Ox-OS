#!/usr/bin/env bash
# Bisect WHO zeroes data.img: check magic after each pipeline stage.
set -eu
IMG=/tmp/ox-boot/payload/data.img
OX="/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
chk() { printf '%s -> %s\n' "$1" "$(head -c6 "$IMG" | xxd -p)"; }

cd "$OX"
OX_DATA_MB=256 bash tools/mkdata.sh "$IMG" >/dev/null
chk "after mkdata"
head -c 16 "$IMG" | xxd | head -1

OX_IMG_FMT=squashfs OX_VERBOSE=0 OX_SKIP_VERITY=1 OX_BUSYBOX=/tmp/ox-aarch64/busybox \
  bash tools/build-payload.sh qemu-virt-aarch64 /tmp/ox-boot/rootfs \
  /tmp/ox-kbuild/Image /tmp/ox-boot/payload >/dev/null 2>&1
chk "after build-payload"

chmod a+r /tmp/ox-boot/payload/* 2>/dev/null || true
bash tools/boot-test.sh /tmp/ox-boot/payload /tmp/ox-kbuild/Image 300 >/dev/null 2>&1 || true
chk "after boot"
