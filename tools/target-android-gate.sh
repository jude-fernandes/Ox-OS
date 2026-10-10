#!/bin/sh
# Android-chain target gate (chunk 75; generalized from the chunk-73
# Fairphone 5 gate) — HOST-SIDE, no board needed. Works for ANY target
# packing the Android chain: boot.img always; dtbo.img / vendor_boot.img
# / vbmeta.img when the target ships them. Asserts the artifacts exist,
# are well-formed, and verify CRYPTOGRAPHICALLY: ox-mkbootimg --verify
# re-parses every boot/vendor_boot image; ox-mkdtbo --verify re-parses
# dtbo when present; AOSP avbtool verify_image checks every AVB
# signature under the dev key (the reference implementation — a
# self-rolled format would prove nothing); the re-lock enrollment value
# (avb-pkmd) is recomputed; the vbmeta rollback baseline is 0; and the
# system slot verifies against its dm-verity tree (THE rootfs the
# 16-gate suite proves). The board remains for M1.
# usage: target-android-gate.sh IMAGE_DIR TAG
set -eu
IMG="$1"
TAG="${2:-android}"
say() { printf '[ox-%s] %s\n' "$TAG" "$*"; }
fail() { printf '[ox-%s] FAIL: %s\n' "$TAG" "$*" >&2; exit 1; }
ok() { printf '[ox-%s] ok: %s\n' "$TAG" "$*"; }

TOOLS="$(cd "$(dirname "$0")" && pwd)"
AVB="$TOOLS/aosp/avbtool.py"

say "checking artifact set in $IMG"
for f in boot.img avb-boot.pk avb-pkmd.bin system.img system.hash.img \
         digest.env README-FLASH.txt; do
    [ -f "$IMG/$f" ] || fail "missing artifact: $f"
done
# optional per-target images: checked if shipped, AVB-verified if present
EXTRA=""
for opt in vendor_boot.img dtbo.img vbmeta.img; do
    [ -f "$IMG/$opt" ] && EXTRA="$EXTRA $opt"
done
ok "core artifacts present; optional set:$EXTRA"

# 1. boot.img: house re-parse (checksums, layout); header version comes
#    from the image itself (fleet uses v2 and v4)
python3 "$TOOLS/ox-mkbootimg.py" --verify --output "$IMG/boot.img" \
    || fail "boot.img does not re-parse"
HV=$(python3 -c "import struct; f=open('$IMG/boot.img','rb'); d=f.read(64); print(struct.unpack_from('<I', d, 40)[0])")
case "$HV" in
    2|4) ok "boot.img re-parses clean, header v$HV" ;;
    *) fail "boot.img header version $HV not in {2,4}" ;;
esac

# 2. vendor_boot.img / dtbo.img: house re-parse when shipped
if [ -f "$IMG/vendor_boot.img" ]; then
    python3 "$TOOLS/ox-mkbootimg.py" --verify --output "$IMG/vendor_boot.img" \
        || fail "vendor_boot.img does not re-parse"
    ok "vendor_boot.img re-parses clean"
fi
HAVE_DTBO=no
if [ -f "$IMG/dtbo.img" ]; then
    python3 "$TOOLS/ox-mkdtbo.py" --verify --output "$IMG/dtbo.img" \
        || fail "dtbo.img does not re-parse"
    ok "dtbo.img re-parses clean"
    HAVE_DTBO=yes
fi

# 3. AVB: the reference verifier under the dev key, on EVERY signed
#    image this target ships
for avbimg in boot.img vendor_boot.img dtbo.img vbmeta.img; do
    [ -f "$IMG/$avbimg" ] || continue
    case "$avbimg" in
        vbmeta.img)
            CHAIN_ARGS=""
            [ -f "$IMG/avb-boot.pk" ] && CHAIN_ARGS="$CHAIN_ARGS --expected_chain_partition boot:1:$IMG/avb-boot.pk"
            [ -f "$IMG/avb-vendor_boot.pk" ] && CHAIN_ARGS="$CHAIN_ARGS --expected_chain_partition vendor_boot:1:$IMG/avb-vendor_boot.pk"
            [ -f "$IMG/avb-dtbo.pk" ] && CHAIN_ARGS="$CHAIN_ARGS --expected_chain_partition dtbo:2:$IMG/avb-dtbo.pk"
            # shellcheck disable=SC2086
            python3 "$AVB" verify_image --image "$IMG/vbmeta.img" \
                --key "$TOOLS/dev-keys/avb-dev.pem" $CHAIN_ARGS >/dev/null 2>&1 \
                || fail "AVB verification failed for vbmeta.img (chain descriptors vs shipped keys)"
            ok "AVB: vbmeta.img verifies; chain descriptors match the shipped keys"
            ;;
        dtbo.img)
            [ "$HAVE_DTBO" = yes ] || fail "dtbo.img present but not re-parsed"
            ;;
        *)
            python3 "$AVB" verify_image --image "$IMG/$avbimg" \
                --key "$TOOLS/dev-keys/avb-dev.pem" >/dev/null 2>&1 \
                || fail "AVB verification failed for $avbimg"
            ok "AVB: $avbimg signature verifies (reference avbtool)"
            ;;
    esac
done

# 4. the re-lock enrollment value is the sha256 of the boot public key
PKMD=$(cat "$IMG/avb-pkmd.bin")
WANT=$(sha256sum "$IMG/avb-boot.pk" | cut -d' ' -f1)
[ "$PKMD" = "$WANT" ] || fail "avb-pkmd does not match sha256(boot pk)"
ok "avb-pkmd = sha256(boot public key): ${PKMD:0:16}..."

# 5. the SIGNED vbmeta's rollback index must be the dev index (0) until
#    M2 (AvbVBMetaImageHeader: rollback_index at offset 112)
if [ -f "$IMG/vbmeta.img" ]; then
    RI=$(python3 -c "import struct; f=open('$IMG/vbmeta.img','rb'); d=f.read(128); print(struct.unpack_from('<Q', d, 112)[0])")
    [ "$RI" = "0" ] || fail "vbmeta rollback index $RI != 0 (dev baseline)"
    ok "vbmeta rollback index 0 (dev baseline; rotation is M2)"
fi

# 6. the system slot verifies against its dm-verity tree
. "$IMG/digest.env"
[ -n "${OX_ROOT_HASH:-}" ] && [ -n "${OX_SALT:-}" ] \
    || fail "digest.env lacks OX_ROOT_HASH/OX_SALT"
veritysetup verify --no-superblock --salt="$OX_SALT" \
    "$IMG/system.img" "$IMG/system.hash.img" "$OX_ROOT_HASH" \
    || fail "dm-verity verification failed"
ok "system slot: dm-verity tree verifies (root hash ${OX_ROOT_HASH:0:16}...)"

say "ALL GREEN — $TAG: Android-chain artifacts built, AVB-signed under the dev key, and reference-verified host-side; the board owes M1"
echo "ANDROID TARGET GATE ALL GREEN ($TAG)"
