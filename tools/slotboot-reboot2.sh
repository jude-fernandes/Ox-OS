#!/bin/sh
# boot the EXISTING debug flash image (hash + metadata already in place)
K=/nix/store/d3d830kxjc22priwv4nl7y0sjra810xr-linux-aarch64-unknown-linux-gnu-6.18.48/Image
P=/nix/store/dyzbibz8vsqvsmn0zj69am83gq6arxxh-ox-payload-qemu-0.1.0-phase1
# rebuild the initramfs cpio from the staged dir (the payload build ships
# the staging dir; the cpio itself is created at pack time in this tree)
if [ ! -f "$P/initramfs.img" ]; then
    (cd "$P/initramfs.dir" && find . | cpio -o -H newc --quiet | gzip > /tmp/ox-slotboot-debug/initramfs.custom)
    INITRD=/tmp/ox-slotboot-debug/initramfs.custom
else
    INITRD="$P/initramfs.img"
fi
echo "INITRD=$INITRD"
LOOP=$(losetup --find --show -P /tmp/ox-slotboot-debug/flash.img)
echo "LOOP=$LOOP"
ls ${LOOP}p5 >/dev/null 2>&1 && echo partitions-ok
timeout 240 qemu-system-aarch64 \
    -machine virt,highmem=off -cpu cortex-a57 -smp 2 -m 1024 \
    -nographic -serial mon:stdio \
    -kernel "$K" -initrd "$INITRD" \
    -append "console=ttyAMA0 printk.time=1 printk.devkmsg=on loglevel=7 ro rdinit=/ox-init ox.slotmeta=/dev/vda5" \
    -drive if=none,file=/tmp/ox-slotboot-debug/flash.img,format=raw,id=hd0 \
    -device virtio-blk-device,drive=hd0 \
    > /tmp/ox-slotboot-debug/boot2.log 2>&1 || true
pkill -f 'ox-slotboot-flash.img' 2>/dev/null || true
losetup -d "$LOOP" 2>/dev/null || true
grep -a -e 'slot' -e FATAL -e corrupted -e 'mounting root' -e stage2 -e confirmed /tmp/ox-slotboot-debug/boot2.log | head -16
