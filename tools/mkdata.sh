#!/usr/bin/env bash
# Create a LUKS2-encrypted data volume image for the Phase-1 virtual target.
#
# DEV-ONLY defaults: PBKDF2 with low iteration count so unlock is fast under
# TCG emulation, and a fixed development passphrase unless OX_DATA_SECRET is
# provided. Production images MUST use Argon2id + user secrets (R-22).
#
# usage: mkdata.sh [IMG_PATH]        (default: /tmp/ox-boot/payload/data.img)
set -eu

IMG="${1:-/tmp/ox-boot/payload/data.img}"
SIZE_MB="${OX_DATA_MB:-256}"
SECRET="${OX_DATA_SECRET:-ox-dev-passphrase-not-for-production}"
KEYFILE="$IMG.key"

command -v cryptsetup >/dev/null || { echo "ERROR: cryptsetup not found" >&2; exit 1; }
[ "$(id -u)" = 0 ] || {
    echo "ERROR: run as root (keyslot activation needs device-mapper)" >&2
    exit 2
}

mkdir -p "$(dirname "$IMG")"
truncate -s "${SIZE_MB}M" "$IMG"
printf '%s' "$SECRET" >"$KEYFILE"
chmod 600 "$KEYFILE"

cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 --key-size 512 \
    --pbkdf pbkdf2 --pbkdf-force-iterations 3000 \
    --batch-mode "$IMG" "$KEYFILE"

cryptsetup close ox-dev-data 2>/dev/null || true
if ! cryptsetup open "$IMG" ox-dev-data --key-file "$KEYFILE" 2>/dev/null; then
    echo "ERROR: failed to open freshly formatted container" >&2
    exit 3
fi

FS=btrfs
if command -v mkfs.btrfs >/dev/null 2>&1; then
    mkfs.btrfs -f -L oxdata "/dev/mapper/ox-dev-data" >/dev/null
else
    FS=ext4
    mkfs.ext4 -F -L oxdata "/dev/mapper/ox-dev-data" >/dev/null 2>&1
fi
cryptsetup close ox-dev-data

printf '%s\n' "$FS" >"$IMG.fs"
echo "[mkdata] $IMG ready ($SIZE_MB MB, luks2 aes-xts-plain64 pbkdf2, fs=$FS)"
