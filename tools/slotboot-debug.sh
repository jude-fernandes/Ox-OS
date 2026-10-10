#!/bin/sh
# diagnostic: build the fresh image + boot it once over the A/B layout;
# keeps the serial log and temp dir for post-mortem.
# exit 0 only if the slot-boot milestone actually appeared in serial.
set -eu
N=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd /root/oxbuild
$N build .#image-pinephone-pro .#kernel-qemu .#payload-qemu \
    --no-link --print-out-paths \
    --option cores 4 --max-jobs 1 2>/tmp/nixerr.txt >/tmp/nixout.txt
PPP=$(head -1 /tmp/nixout.txt)
KOUT=$(sed -n 2p /tmp/nixout.txt)
PQ=$(sed -n 3p /tmp/nixout.txt)
echo "PPP=$PPP"
echo "KOUT=$KOUT"
echo "PQ=$PQ"
WORK=/tmp/ox-slotboot-debug
rm -rf "$WORK"
mkdir -p "$WORK"
truncate -s 9G "$WORK/flash.img"
LOOP=$(losetup --find --show "$WORK/flash.img")
bash /root/oxbuild/targets/pinephone-pro/ox-flash.sh "$LOOP" "$PPP" > "$WORK/flash.log" 2>&1
losetup -d "$LOOP"
sleep 2
LOOP=$(losetup --find --show -P "$WORK/flash.img")
ls -la ${LOOP}p* 2>/dev/null | head -8
cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 \
    --pbkdf-force-iterations 10000 --batch-mode \
    --key-file "$PPP/data.img.key" "${LOOP}p6" >/dev/null
timeout 240 qemu-system-aarch64 \
    -machine virt,highmem=off -cpu cortex-a57 -smp 2 -m 1024 \
    -display none -monitor none -serial "file:$WORK/boot.log" \
    -kernel "$KOUT/Image" \
    -initrd "$PQ/initramfs.img" \
    -append "console=ttyAMA0 earlycon=pl011,0x09000000 printk.time=1 printk.devkmsg=on loglevel=7 ro rdinit=/ox-init ox.slotmeta=/dev/vda5 ox.pm_drill=off" \
    -drive if=none,file="$WORK/flash.img",format=raw,id=hd0 \
    -device virtio-blk-device,drive=hd0 \
    </dev/null >/dev/null 2>&1 || true
pkill -f 'ox-slotboot-debug/flash.img' 2>/dev/null || true
losetup -d "$LOOP" 2>/dev/null || true
echo "=== slot lines in serial:"
grep -a -n -e slot -e FATAL -e confirmed -e oxsys -e 'mounting root' "$WORK/boot.log" | head -20
# exit status must reflect reality: grep|head above always exits 0
grep -aq 'name=slot-boot slot=0' "$WORK/boot.log" || {
    echo "DEBUG FAIL: no slot-boot milestone in serial"; exit 1; }
echo "DEBUG PASS: slot-boot milestone observed"
