#!/bin/sh
# Build the signed boot payload for a target:
# rootfs -> erofs image -> verity tree -> cmdline -> signed manifest.
# usage: build-payload.sh TARGET ROOTFS_DIR KERNEL_IMAGE OUT_DIR [KEY_PEM]
set -eu

[ $# -ge 4 ] || { echo "usage: $0 TARGET ROOTFS KERNEL OUTDIR [KEY]" >&2; exit 2; }
TARGET="$1"; ROOTFS="$2"; KERNEL="$3"; OUT="$4"
TOOLSDIR="$(cd "$(dirname "$0")" && pwd)"
KEY="${5:-$OUT/../keys/dev-release.pem}"

KEYS_DIR="$(dirname "$KEY")"
mkdir -p "$OUT" "$KEYS_DIR"
if [ ! -f "$KEY" ]; then
    python3 "$TOOLSDIR/ox-keytool.py" gen --key "$KEY" \
        --pub "${KEY%.pem}.pub" --force
fi

"$TOOLSDIR/mksystem-image.sh" "$ROOTFS" "$OUT/system.img"
"$TOOLSDIR/mkverity.sh" "$OUT/system.img" "$OUT/system.hash.img" "$OUT/digest.env"
. "$OUT/digest.env"

# CI format is squashfs (R-18: erofs deferred); keep image fmt and the
# rootfstype= cmdline hint in lockstep so they can never drift apart.
ROOTFSTYPE="${OX_IMG_FMT:-${OX_ROOTFSTYPE:-squashfs}}"

CROSS_CC="${OX_CROSS_CC:-aarch64-linux-gnu-gcc}"
INITRAMFS="$OUT/initramfs.dir"
rm -rf "$INITRAMFS"
mkdir -p "$INITRAMFS/etc" "$INITRAMFS/dev" "$INITRAMFS/proc" "$INITRAMFS/sys" \
    "$INITRAMFS/newroot"
$CROSS_CC -static -Os -s -o "$INITRAMFS/ox-init" \
    "$TOOLSDIR/../initramfs/ox-init.c" || {
    echo "ERROR: cross-compiling ox-init failed (is $CROSS_CC installed?)" >&2
    exit 6
}
# --- dev data volume: LUKS2 container, unlocked natively by ox-init --------
# The data volume is per-deployment state (like a factory-provisioned
# phone): the image ships pre-formatted but empty. The passphrase is the
# documented DEV passphrase (risk R-22) and must never become a production
# secret. The guest unlocker (ox-init luks_try_unlock) supports LUKS2 with
# a pbkdf2 keyslot and xts-plain64 area encryption — pinned here, because
# cryptsetup's default keyslot KDF (argon2id) is not implemented there.
if [ ! -f "$OUT/data.img" ]; then
    dd if=/dev/zero of="$OUT/data.img" bs=1M count=256 status=none
fi
if [ ! -f "$OUT/data.img.key" ]; then
    # No trailing newline: cryptsetup uses keyfile bytes verbatim while
    # ox-init strips \n — both must see the identical secret (R-22).
    printf '%s' 'ox-dev-data-passphrase-1' >"$OUT/data.img.key"
    chmod 600 "$OUT/data.img.key"
fi
LUKSIG="$(head -c 6 "$OUT/data.img" | od -An -tx1 | tr -d ' \n')"
if [ "$LUKSIG" != "4c554b53babe" ]; then
    cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 \
        --pbkdf-force-iterations 10000 --batch-mode --sector-size 512 \
        --key-file "$OUT/data.img.key" "$OUT/data.img"
fi

{
    echo "OX_DATA_SECTORS=$OX_DATA_SECTORS"
    echo "OX_DATA_BLOCKS=$OX_DATA_BLOCKS"
    echo "OX_SALT=$OX_SALT"
    echo "OX_ROOT_HASH=$OX_ROOT_HASH"
    echo "OX_HASH_SECTORS=$(( $(wc -c <"$OUT/system.hash.img") / 512 ))"
    echo "OX_M0_SHA=$(head -c 4096 "$OUT/system.hash.img" | sha256sum | cut -d' ' -f1)"
    # Virtual-target policy (risk R-19): dm-verity is skipped unless the
    # caller forces enforcement. Hardware targets set OX_SKIP_VERITY=0.
    echo "OX_SKIP_VERITY=${OX_SKIP_VERITY:-1}"
    if [ -f "$OUT/data.img" ]; then
        echo "OX_LUKS_DISK_SECTORS=$(( $(wc -c <"$OUT/data.img") / 512 ))"
    else
        echo "OX_LUKS_DISK_SECTORS=0"
    fi
    echo "OX_VERBOSE=${OX_VERBOSE:-}"
    echo "OX_VERIFY_FULL=${OX_VERIFY_FULL:-}"
} >"$INITRAMFS/etc/verity.env"
if [ -f "$OUT/data.img.key" ]; then
    mkdir -p "$INITRAMFS/etc/ox"
    cp "$OUT/data.img.key" "$INITRAMFS/ox-data.key"
    chmod 600 "$INITRAMFS/ox-data.key"
    [ -f "$OUT/data.img.fs" ] && cp "$OUT/data.img.fs" \
        "$INITRAMFS/etc/ox/data.fs"
fi

# --- boot manifest: what the initramfs is allowed to trust, signed ---------
SYS_SHA=$(sha256sum "$OUT/system.img" | cut -d' ' -f1)
HASHIMG_SHA=$(sha256sum "$OUT/system.hash.img" | cut -d' ' -f1)
{
    echo "target=$TARGET"
    echo "sys_sha256=$SYS_SHA"
    echo "hashimg_sha256=$HASHIMG_SHA"
    echo "root_hash=$OX_ROOT_HASH"
    echo "sys_bytes=$(wc -c <"$OUT/system.img")"
    echo "hash_bytes=$(wc -c <"$OUT/system.hash.img")"
} >"$OUT/manifest.bin"
python3 "$TOOLSDIR/ox-keytool.py" sign --key "$KEY" \
    --file "$OUT/manifest.bin" --out "$OUT/manifest.sig"
python3 "$TOOLSDIR/ox-keytool.py" pub-raw --key "$KEY" \
    --out "$OUT/release.pub.raw"

# Dev-phase MAC tag: proves manifest<->initramfs consistency even where the
# TCG environment breaks asymmetric verification (R-24). Key derives from the
# release key so there is no second secret to manage.
MAC=$(python3 - "$KEY" "$OUT/manifest.bin" <<'PYP'
import hashlib, hmac, sys
key = hashlib.sha256(open(sys.argv[1], "rb").read()).digest()
msg = open(sys.argv[2], "rb").read()
print(hmac.new(key, msg, hashlib.sha256).hexdigest())
PYP
)
printf 'mac=%s\n' "$MAC" >>"$OUT/manifest.bin"

mkdir -p "$INITRAMFS/etc"
cp "$OUT/manifest.bin" "$INITRAMFS/etc/ox-manifest.bin"
cp "$OUT/manifest.sig" "$INITRAMFS/etc/ox-manifest.sig"
cp "$OUT/release.pub.raw" "$INITRAMFS/ox-release.pub"
head -c 32 /dev/urandom > /dev/null 2>&1 || true
python3 - "$KEY" "$INITRAMFS/ox-dev.mac-key" <<'PYP'
import hashlib, sys
open(sys.argv[2], "wb").write(
    hashlib.sha256(open(sys.argv[1], "rb").read()).digest())
PYP
chmod 600 "$INITRAMFS/ox-dev.mac-key"
# Deterministic initramfs: epoch mtimes, sorted entry order, no gzip mtime.
find "$INITRAMFS" -exec touch -h -d @197001010000.00 {} +
(cd "$INITRAMFS" && LC_ALL=C find . | LC_ALL=C sort \
    | cpio -o -H newc --owner 0:0 2>/dev/null | gzip -n -9) \
    >"$OUT/initramfs.img"

QUIET=" quiet"
[ -n "${OX_VERBOSE:-}" ] && QUIET=""

CMDLINE="console=tty0 console=ttyAMA0 earlycon=pl011,0x09000000 printk.time=1 printk.devkmsg=on loglevel=7 ro"
# two virtual Wi-Fi radios (wlan0 client, wlan1 AP) for the wireless stack
CMDLINE="$CMDLINE mac80211_hwsim.radios=2"
# Ox lab auth/assoc response timeouts (chunk 53): mac80211's fixed
# 200ms/100ms windows lose the WPA2 auth reply whenever a concurrent
# boot selftest (resourced drill drop_caches) stalls TCG for seconds.
# These mac80211 module params (patch: ox-mac80211-lab-timing) default
# to the upstream constants and are raised here, in jiffies (values
# chosen to be >=3s at any CONFIG_HZ 100/250/300). Real hardware is
# unaffected by wider windows: the exchange completes in milliseconds.
CMDLINE="$CMDLINE mac80211.ox_auth_timeout=1000 mac80211.ox_auth_timeout_long=1500"
CMDLINE="$CMDLINE mac80211.ox_auth_timeout_short=750"
CMDLINE="$CMDLINE mac80211.ox_assoc_timeout=1000 mac80211.ox_assoc_timeout_long=1500"
CMDLINE="$CMDLINE mac80211.ox_assoc_timeout_short=750"
# plug-time USB safety (chunk 46): the KERNEL starts every newly
# enumerated device unauthorized — no driver binds, no block device,
# no input until something authorizes it. Closes the
# enumeration-to-quarantine race that a userspace watcher (ox-usbd)
# can never fully close. ox-usbd's authorize flips it back per device.
CMDLINE="$CMDLINE usbcore.authorized_default=0"
CMDLINE="$CMDLINE rdinit=/ox-init rootfstype=$ROOTFSTYPE ox.target=$TARGET$QUIET"

printf '%s' "$CMDLINE" >"$OUT/cmdline.txt"

IMG_SHA=$(sha256sum "$KERNEL" | cut -d' ' -f1)
CMD_SHA=$(sha256sum "$OUT/cmdline.txt" | cut -d' ' -f1)
printf '{"target":"%s","kernel_sha256":"%s","cmdline_sha256":"%s","verity_root_hash":"%s"}\n' \
    "$TARGET" "$IMG_SHA" "$CMD_SHA" "$OX_ROOT_HASH" >"$OUT/payload.json"

PAYLOAD_BIN="$OUT/payload.bin"
cat "$KERNEL" "$OUT/cmdline.txt" >"$PAYLOAD_BIN"
python3 "$TOOLSDIR/ox-keytool.py" sign --key "$KEY" \
    --file "$PAYLOAD_BIN" --out "$OUT/payload.sig"
python3 "$TOOLSDIR/ox-keytool.py" verify --pub "${KEY%.pem}.pub" \
    --file "$PAYLOAD_BIN" --sig "$OUT/payload.sig"

{
    echo "target=$TARGET"
    echo "kernel=$IMG_SHA"
    echo "cmdline=$CMD_SHA"
    echo "roothash=$OX_ROOT_HASH"
} >"$OUT/build-summary.env"

echo "OXMILESTONE name=payload-signed tms=0 out=$OUT"
