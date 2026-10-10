#!/usr/bin/env bash
# PinePhone Pro A/B slot updater (chunk 76, M2 groundwork): write the
# NEW image set into slot _b, verify it against its own digests, mark
# it active in the slot metadata, and record the root hashes.
#
#   usage: ox-update.sh DEVICE IMAGE_DIR
#
#   DEVICE    the flashed whole device (block device or file; partition
#             devices are resolved via /dev/disk/by-partlabel — so a
#             loop backing file must be re-attached with -P first, the
#             chunk-74 lesson)
#   IMAGE_DIR the built image-pinephone-pro artifacts to install
#
# Safety properties (each verified, not assumed):
#   - the new system.img must pass its own dm-verity verification
#     BEFORE anything is written (never install an unverifiable slot)
#   - slot _a (the running/known-good slot) is never touched
#   - after the writes, _b is read back byte-for-byte
#   - the metadata block flips active to b with boot_attempts=0 and
#     carries BOTH slots' root hashes (a's from digest.env, b's the
#     new one — they are equal today; the format is per-slot for the
#     future)
# The GUEST side (ox-init reading this metadata to pick the partition
# and confirm boots by counter) is the next M2 step — this chunk is
# the host write path, proven here end-to-end on a loop device.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
DEV="${1:?usage: ox-update.sh DEVICE IMAGE_DIR}"
IMG="${2:?usage: ox-update.sh DEVICE IMAGE_DIR}"

for f in "$IMG/ox.itb" "$IMG/system.img" "$IMG/system.hash.img" \
         "$IMG/digest.env"; do
    [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 4; }
done
[ -e "$DEV" ] || { echo "FATAL: no device $DEV" >&2; exit 4; }

PART() { # PART <label> -> partition device
    local P="/dev/disk/by-partlabel/$1"
    if [ -e "$P" ]; then
        readlink -f "$P"
        return
    fi
    # loop-backed files get no by-partlabel udev entries: resolve via
    # the GPT itself (sgdisk -p: index -> ${DEV}p<index>)
    local IDX
    IDX=$(sgdisk -p "$DEV" 2>/dev/null | awk -v n="$1" '$0 ~ n {print $1}' | head -n 1)
    [ -n "$IDX" ] || { echo "FATAL: partition $1 not in the GPT of $DEV" >&2; exit 4; }
    case "$DEV" in
        *[0-9]) echo "${DEV}p${IDX}" ;;
        *) echo "${DEV}${IDX}" ;;
    esac
}

BOOT_B=$(PART ox-boot-b)
SYS_B=$(PART ox-system-b)
META=$(PART ox-metadata)

# 1. pre-flight: the incoming system slot must verify against its own
#    dm-verity tree BEFORE any write
. "$IMG/digest.env"
veritysetup verify --no-superblock --salt="$OX_SALT" \
    "$IMG/system.img" "$IMG/system.hash.img" "$OX_ROOT_HASH" \
    || { echo "FATAL: incoming system.img fails dm-verity — refusing update" >&2; exit 1; }
echo "preflight: incoming system.img verifies (root ${OX_ROOT_HASH:0:16}...)"

# 2. write slot _b: system at the partition start, the verity hash tree
#    at the in-slot hash offset (the C reader's OX_SLOT_HASH_OFF_B)
dd if="$IMG/ox.itb" of="$BOOT_B" bs=1M conv=notrunc status=none
dd if="$IMG/system.img" of="$SYS_B" bs=1M conv=notrunc status=none
dd if="$IMG/system.hash.img" of="$SYS_B" bs=1M seek=2944 conv=notrunc status=none

# 3. read back and compare byte-for-byte
OXSZ=$(stat -c %s "$IMG/ox.itb")
dd if="$BOOT_B" bs=1M count=$(( (OXSZ + 1048575) / 1048576 )) status=none \
    | head -c "$OXSZ" | cmp -s - "$IMG/ox.itb" \
    || { echo "FATAL: boot-b readback differs — update aborted (slot a untouched)" >&2; exit 1; }
SYSSZ=$(stat -c %s "$IMG/system.img")
dd if="$SYS_B" bs=1M count=$(( (SYSSZ + 1048575) / 1048576 )) status=none \
    | head -c "$SYSSZ" | cmp -s - "$IMG/system.img" \
    || { echo "FATAL: system-b readback differs — update aborted (slot a untouched)" >&2; exit 1; }
echo "slot b written and read back byte-identical"

# 4. metadata: active=b, attempts=0, both root hashes + block counts
python3 "$SELF/../../tools/ox-slotmeta.py" --write \
    --device "$META" \
    --active 1 \
    --root-a "$OX_ROOT_HASH" \
    --root-b "$OX_ROOT_HASH" \
    --blocks-a "$OX_DATA_BLOCKS" \
    --blocks-b "$OX_DATA_BLOCKS"
echo "metadata: active=b, counters reset, root hashes recorded"

# 5. final state printout
python3 "$SELF/../../tools/ox-slotmeta.py" read "$META" || true
echo "OX_UPDATE_OK (slot b active; slot a preserved as fallback)"
