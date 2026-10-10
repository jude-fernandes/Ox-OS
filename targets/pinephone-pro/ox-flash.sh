#!/usr/bin/env bash
# PinePhone Pro flash script (chunk 74, BRINGUP M1-prep): write the
# verified artifacts onto a block device with the BRINGUP.md layout.
#
#   usage: ox-flash.sh DEVICE IMAGE_DIR [DATA_TARGET]
#
#   DEVICE       the whole target: a block device, or a plain file
#                (the gate loops it with -P so partitions appear)
#   IMAGE_DIR    the built image-pinephone-pro artifacts
#   DATA_TARGET  optional: the ox-data partition device (e.g. /dev/sda5
#                or the loop partition); when given it is LUKS2-formatted
#                under the payload dev key (R-22 documented; owner re-key
#                at provisioning). Without it, data formatting is left to
#                provisioning (first boot / owner flow).
#
# Layout (BRINGUP.md flash table):
#   sector 64 (0x8000)   idbloader.img — the rk3399 bootrom loads here;
#                         the BRINGUP table's "0x0" row is the
#                         head-of-disk region; sector 64 keeps the GPT
#                         intact (idbloader ~190KB ends before 0x80000)
#   0x80000              u-boot.itb (unsigned until M2)
#   GPT partitions (16MiB-aligned, device-adaptive — "data = rest" at
#   provisioning; this script sizes data at DATA_MIB=512 default):
#     ox-boot-a/b 64MiB   ox.itb (SIGNED FIT) in _a
#     ox-system-a/b 3GiB  system.img (erofs+dm-verity) in _a
#     ox-metadata 16MiB    slot counters (M2)
#     ox-data     default 512MiB, LUKS2
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
DEV="${1:?usage: ox-flash.sh DEVICE IMAGE_DIR [DATA_TARGET]}"
IMG="${2:?usage: ox-flash.sh DEVICE IMAGE_DIR [DATA_TARGET]}"
DATA_TARGET="${3:-}"
DATA_MIB=512

for f in "$IMG/idbloader.img" "$IMG/u-boot.itb" "$IMG/ox.itb" \
         "$IMG/system.img" "$IMG/data.img.key"; do
    [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 4; }
done
[ -b "$DEV" ] || [ -f "$DEV" ] || { echo "FATAL: $DEV is not a device or file" >&2; exit 4; }
if [ -n "$DATA_TARGET" ] && [ ! -e "$DATA_TARGET" ]; then
    echo "FATAL: DATA_TARGET $DATA_TARGET does not exist" >&2
    exit 4
fi

MIB=2048  # sectors per MiB
BOOT_START=16;    BOOT_SIZE=64
BOOTB_START=$((BOOT_START + BOOT_SIZE)); BOOTB_SIZE=64
SYSA_START=$((BOOTB_START + BOOTB_SIZE)); SYSA_SIZE=3072
SYSB_START=$((SYSA_START + SYSA_SIZE));  SYSB_SIZE=3072
META_START=$((SYSB_START + SYSB_SIZE));  META_SIZE=16
DATA_START=$((META_START + META_SIZE))

# 1. fresh table
sgdisk --zap-all "$DEV" >/dev/null

# 2. boot firmware: bootrom convention + BRINGUP offsets
dd if="$IMG/idbloader.img" of="$DEV" bs=512 seek=64 conv=notrunc status=none
dd if="$IMG/u-boot.itb" of="$DEV" bs=1 seek=$((0x80000)) conv=notrunc status=none

# 3. GPT partitions (SIX: boot_a/b, system_a/b, metadata, data)
sgdisk -n "1:$((BOOT_START * MIB)):+$((BOOT_SIZE * MIB))" -c "1:ox-boot-a" "$DEV" >/dev/null
sgdisk -n "2:$((BOOTB_START * MIB)):+$((BOOTB_SIZE * MIB))" -c "2:ox-boot-b" "$DEV" >/dev/null
sgdisk -n "3:$((SYSA_START * MIB)):+$((SYSA_SIZE * MIB))" -c "3:ox-system-a" "$DEV" >/dev/null
sgdisk -n "4:$((SYSB_START * MIB)):+$((SYSB_SIZE * MIB))" -c "4:ox-system-b" "$DEV" >/dev/null
sgdisk -n "5:$((META_START * MIB)):+$((META_SIZE * MIB))" -c "5:ox-metadata" "$DEV" >/dev/null
sgdisk -n "6:$((DATA_START * MIB)):+$((DATA_MIB * MIB))" -c "6:ox-data" "$DEV" >/dev/null

# 4. slot contents (slot _a only; _b is the updater's, M2): system at
    # the partition start, the verity hash tree at the in-slot offset
    # (the C reader's OX_SLOT_HASH_OFF_B — same convention as ox-update)
dd if="$IMG/ox.itb" of="$DEV" bs=1M seek="$BOOT_START" conv=notrunc status=none
dd if="$IMG/system.img" of="$DEV" bs=1M seek="$SYSA_START" conv=notrunc status=none
dd if="$IMG/system.hash.img" of="$DEV" bs=1M seek="$((SYSA_START + 2944))" conv=notrunc status=none

# 5. data volume: LUKS2 under the payload dev key when a data target
#    was provided
if [ -n "$DATA_TARGET" ]; then
    cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 \
        --pbkdf-force-iterations 10000 --batch-mode \
        --key-file "$IMG/data.img.key" "$DATA_TARGET" >/dev/null
    echo "ox-data: LUKS2 formatted ($DATA_TARGET, dev key)"
fi

# 5. initial slot metadata: slot a active, root hash + block count from
#    the payload's digest.env (slot b recorded identically — the updater
#    rewrites it with the new root at update time)
if [ -f "$IMG/digest.env" ]; then
    . "$IMG/digest.env"
    python3 "$SELF/../../tools/ox-slotmeta.py" --write \
        --device "$DEV" \
        --offset-bytes "$((META_START * 1024 * 1024))" \
        --active 0 \
        --root-a "$OX_ROOT_HASH" \
        --root-b "$OX_ROOT_HASH" \
        --blocks-a "${OX_DATA_BLOCKS:-0}" \
        --blocks-b "${OX_DATA_BLOCKS:-0}" >/dev/null
    echo "ox-metadata: initial block written (active=a)"
fi

echo "flashed $DEV: idbloader@sector64 + u-boot.itb@0x80000 + GPT (ox-boot-a/b 64M, ox-system-a/b 3G, ox-metadata 16M, ox-data ${DATA_MIB}M); slot _a filled, slot _b for the updater"
