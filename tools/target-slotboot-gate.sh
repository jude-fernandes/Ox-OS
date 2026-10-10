#!/bin/sh
# Slot-boot gate (chunk 77) — HOST-SIDE: boot the FLASHED A/B layout in
# qemu and prove the guest stage-1 slot reader + stage-2 confirm.
#
#   flash (ox-flash, six partitions, LUKS data) -> BOOT 1: slot a boots,
#   slot-confirm fires (attempts reset, boot_count_a = 1) -> set
#   attempts=3 on active b via ox-update + metadata pre-set -> BOOT 2:
#   stage-1 rolls back to slot a (slot-rollback milestone) and confirms
#   again (boot_count_a = 2).
#
# The qemu guest boots with the QEMU kernel (virtio disks) against the
# flashed image; ox.slotmeta=/dev/vda5 in the cmdline enables slot mode.
# usage: target-slotboot-gate.sh PPP_IMAGE_DIR QEMU_KERNEL INITRAMFS
set -eu
PPP="$1"
KERNEL="$2"
INITRD="$3"
say() { printf '[ox-slotboot] %s\n' "$*"; }
fail() { printf '[ox-slotboot] FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf '[ox-slotboot] ok: %s\n' "$*"; }

TOOLS="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d)
SERIAL="$WORK/serial.log"
cleanup() {
    pkill -f 'ox-slotboot-flash.img' 2>/dev/null || true
    # keep the serial logs for post-mortem (a deleted boot log is an
    # unreadable failure)
    mkdir -p /tmp/ox-slotboot-logs
    cp -f "$WORK"/boot*.log /tmp/ox-slotboot-logs/ 2>/dev/null || true
    losetup -d "$LOOP" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

say "flashing the A/B layout (six partitions, LUKS data)"
truncate -s 9G "$WORK/ox-slotboot-flash.img"
# loop attach can transiently fail right after heavy rebuilds (device
# node re-creation); retry once
LOOP=$(losetup --find --show "$WORK/ox-slotboot-flash.img" 2>/dev/null || true)
[ -b "$LOOP" ] || { sleep 5; LOOP=$(losetup --find --show "$WORK/ox-slotboot-flash.img"); }
[ -b "$LOOP" ] || fail "cannot attach loop device"
bash "$TOOLS/../targets/pinephone-pro/ox-flash.sh" "$LOOP" "$PPP" \
    > "$WORK/flash.log" 2>&1 || { cat "$WORK/flash.log" >&2; fail "flash failed"; }
losetup -d "$LOOP"
sleep 2
LOOP=$(losetup --find --show -P "$WORK/ox-slotboot-flash.img" 2>/dev/null || true)
[ -b "$LOOP" ] || { sleep 5; LOOP=$(losetup --find --show -P "$WORK/ox-slotboot-flash.img"); }
[ -b "${LOOP}p5" ] || fail "partition scan failed"
cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 \
    --pbkdf-force-iterations 10000 --batch-mode \
    --key-file "$PPP/data.img.key" "${LOOP}p6" >/dev/null
ok "flashed + data partition LUKS2"

boot_qemu() { # boot_qemu <log>
    rm -f "$1"
    # -serial file: + no stdio chardev: with -nographic the stdio mux
    # touches the controlling terminal's termios, and a background job
    # (queue watcher) gets SIGTTOU and freezes before printing a byte.
    # A file chardev has no fd-0 dependency at all.
    timeout 900 qemu-system-aarch64 \
        -machine virt,highmem=off -cpu cortex-a57 -smp 2 -m 1024 \
        -display none -monitor none -serial "file:$1" \
        -kernel "$KERNEL" -initrd "$INITRD" \
        -append "console=ttyAMA0 earlycon=pl011,0x09000000 printk.time=1 printk.devkmsg=on loglevel=7 ro rdinit=/ox-init ox.slotmeta=/dev/vda5 ox.pm_drill=off" \
        -drive if=none,file="$WORK/ox-slotboot-flash.img",format=raw,id=hd0 \
        -device virtio-blk-device,drive=hd0 \
        </dev/null >/dev/null 2>&1 || true
    pkill -f 'ox-slotboot-flash.img' 2>/dev/null || true
}

wait_pat() { # wait_pat <log> <pattern> <seconds> <label>
    i=0
    while [ $i -lt $(($3 / 2)) ]; do
        grep -aq "$2" "$1" 2>/dev/null && return 0
        sleep 2
        i=$((i + 1))
    done
    fail "$4 (pattern not observed: $2)"
}

# ---------------------------------------------------------- BOOT 1 ----
say "BOOT 1: slot a first boot (attempts counted, then confirmed)"
boot_qemu "$WORK/boot1.log"
wait_pat "$WORK/boot1.log" "name=slot-boot slot=0" 600 "stage-1 slot-boot slot=0"
wait_pat "$WORK/boot1.log" "name=slot-root slot=0" 300 "stage-1 mounted slot a root"
wait_pat "$WORK/boot1.log" "stage2-begin" 300 "stage-2 started"
wait_pat "$WORK/boot1.log" "name=slot-confirmed slot=0 count=1" 600 "oxctl slot-confirmed"
ok "boot 1: slot a selected, mounted, confirmed (count=1)"

# metadata on disk: attempts reset, counts recorded
python3 "$TOOLS/ox-slotmeta.py" read "${LOOP}p5" > "$WORK/meta1.txt"
grep -q "boot_attempts=0" "$WORK/meta1.txt" || fail "attempts not reset after confirm"
grep -q "boot_count_a=1" "$WORK/meta1.txt" || fail "boot_count_a != 1"
grep -q "active_slot=0" "$WORK/meta1.txt" || fail "active slot != a"
ok "metadata: attempts=0, boot_count_a=1, active=a"

# --------------------------------------------- UPDATE + EXHAUSTION ----
say "update: fill slot b (valid), then pre-exhaust its attempts"
bash "$TOOLS/../targets/pinephone-pro/ox-update.sh" "$LOOP" "$PPP" \
    > "$WORK/update.log" 2>&1 || { cat "$WORK/update.log" >&2; fail "ox-update failed"; }
. "$PPP/digest.env"
# preserve the boot count boot 1 earned: a harness rewrite that drops
# it would fake "this slot never booted" (count=1 on the next confirm)
CA=$(sed -n 's/.*boot_count_a=\([0-9]*\).*/\1/p' "$WORK/meta1.txt")
python3 "$TOOLS/ox-slotmeta.py" --write --device "${LOOP}p5" \
    --active 1 --attempts 3 --count-a "${CA:-0}" --count-b 0 \
    --root-a "$OX_ROOT_HASH" --root-b "$OX_ROOT_HASH" \
    --blocks-a "$OX_DATA_BLOCKS" --blocks-b "$OX_DATA_BLOCKS"
ok "slot b active with attempts=3 (exhaustion pre-set)"

# ---------------------------------------------------------- BOOT 2 ----
say "BOOT 2: stage-1 must roll back to slot a"
boot_qemu "$WORK/boot2.log"
wait_pat "$WORK/boot2.log" "name=slot-rollback from=1 attempts=3" 600 "stage-1 rollback fired"
# the milestone carries the pre-count: slot=0 attempts=1 rollback=1
wait_pat "$WORK/boot2.log" "slot=0 attempts=1 rollback=1" 300 "stage-1 fell back to slot a"
wait_pat "$WORK/boot2.log" "stage2-begin" 300 "stage-2 started from slot a"
wait_pat "$WORK/boot2.log" "name=slot-confirmed slot=0 count=2" 600 "confirm counted boot 2"
ok "boot 2: rolled back to slot a, confirmed (count=2)"

python3 "$TOOLS/ox-slotmeta.py" read "${LOOP}p5" > "$WORK/meta2.txt"
grep -q "active_slot=0" "$WORK/meta2.txt" || fail "metadata active != a after rollback"
grep -q "boot_attempts=0" "$WORK/meta2.txt" || fail "attempts not reset after rollback confirm"
grep -q "boot_count_a=2" "$WORK/meta2.txt" || fail "boot_count_a != 2"
grep -q "boot_count_b=0" "$WORK/meta2.txt" || fail "boot_count_b changed unexpectedly"
ok "metadata: active back to a, counts consistent"

say "ALL GREEN — slot-boot: metadata-driven slot selection, pre-count, confirm, and exhaustion rollback are proven in real boots"
echo "SLOT-BOOT TARGET GATE ALL GREEN"
