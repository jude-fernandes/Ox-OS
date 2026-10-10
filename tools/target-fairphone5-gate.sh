#!/bin/sh
# Fairphone 5 target gate (chunk 73) — HOST-SIDE, no board needed.
# Asserts the Android-chain artifacts exist, are well-formed, and
# verify CRYPTOGRAPHICALLY: ox-mkbootimg --verify re-parses boot.img;
# ox-mkdtbo --verify re-parses dtbo.img; AOSP avbtool verify_image
# checks the AVB signatures of boot/dtbo/vbmeta under the dev key
# (the reference implementation — a self-rolled format would prove
# nothing); the re-lock enrollment value (avb-pkmd) is recomputed; and
# the system slot verifies against its dm-verity tree (THE rootfs the
# 16-gate suite proves). The board remains for M1 (unlock/relock).
# usage: target-fairphone5-gate.sh IMAGE_DIR
set -eu
IMG="$1"
say() { printf '[ox-fp5] %s\n' "$*"; }
fail() { printf '[ox-fp5] FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf '[ox-fp5] ok: %s\n' "$*"; }

TOOLS="$(cd "$(dirname "$0")" && pwd)"
AVB="$TOOLS/aosp/avbtool.py"

say "checking artifact set in $IMG"
for f in boot.img dtbo.img vbmeta.img avb-boot.pk avb-pkmd.bin \
         system.img system.hash.img digest.env README-FLASH.txt; do
    [ -f "$IMG/$f" ] || fail "missing artifact: $f"
done
ok "all 9 artifacts present"

# 1. boot.img: house re-parse (checksums, layout) + v4 header
python3 "$TOOLS/ox-mkbootimg.py" --verify --output "$IMG/boot.img" \
    || fail "boot.img does not re-parse"
HV=$(python3 -c "import struct,sys; f=open('$IMG/boot.img','rb'); d=f.read(64); print(struct.unpack_from('<I', d, 40)[0])")
[ "$HV" = "4" ] || fail "boot.img header version $HV != 4"
ok "boot.img re-parses clean, header v4"

# 2. dtbo.img: house re-parse (magic, size accounting, FDT blobs)
python3 "$TOOLS/ox-mkdtbo.py" --verify --output "$IMG/dtbo.img" \
    || fail "dtbo.img does not re-parse"
ok "dtbo.img re-parses clean"

# 3. AVB: the reference verifier, under the dev key, on all three
python3 "$AVB" verify_image --image "$IMG/boot.img" \
    --key "$TOOLS/dev-keys/avb-dev.pem" >/dev/null 2>&1 \
    || fail "AVB verification failed for boot.img"
ok "AVB: boot.img signature verifies (reference avbtool)"
python3 "$AVB" verify_image --image "$IMG/dtbo.img" \
    --key "$TOOLS/dev-keys/avb-dev.pem" >/dev/null 2>&1 \
    || fail "AVB verification failed for dtbo.img"
ok "AVB: dtbo.img signature verifies (reference avbtool)"
python3 "$AVB" verify_image --image "$IMG/vbmeta.img" \
    --key "$TOOLS/dev-keys/avb-dev.pem" \
    --expected_chain_partition "boot:1:$IMG/avb-boot.pk" \
    --expected_chain_partition "dtbo:2:$IMG/avb-dtbo.pk" >/dev/null 2>&1 \
    || fail "AVB verification failed for vbmeta.img (chain descriptors vs shipped keys)"
ok "AVB: vbmeta.img verifies; chain descriptors match the shipped boot/dtbo keys"

# 4. the re-lock enrollment value is the sha256 of the boot public key
PKMD=$(cat "$IMG/avb-pkmd.bin")
WANT=$(sha256sum "$IMG/avb-boot.pk" | cut -d' ' -f1)
[ "$PKMD" = "$WANT" ] || fail "avb-pkmd does not match sha256(boot pk)"
ok "avb-pkmd = sha256(boot public key): ${PKMD:0:16}..."

# 5. the SIGNED vbmeta's rollback index must be the dev index (0) until
#    M2 (AvbVBMetaImageHeader: rollback_index at offset 112)
RI=$(python3 -c "import struct; f=open('$IMG/vbmeta.img','rb'); d=f.read(128); print(struct.unpack_from('<Q', d, 112)[0])")
[ "$RI" = "0" ] || fail "vbmeta rollback index $RI != 0 (dev baseline)"
ok "vbmeta rollback index 0 (dev baseline; rotation is M2)"

# 6. the system slot verifies against its dm-verity tree
. "$IMG/digest.env"
[ -n "${OX_ROOT_HASH:-}" ] && [ -n "${OX_SALT:-}" ] \
    || fail "digest.env lacks OX_ROOT_HASH/OX_SALT"
veritysetup verify --no-superblock --salt="$OX_SALT" \
    "$IMG/system.img" "$IMG/system.hash.img" "$OX_ROOT_HASH" \
    || fail "dm-verity verification failed"
ok "system slot: dm-verity tree verifies (root hash ${OX_ROOT_HASH:0:16}...)"

say "ALL GREEN — fairphone5 target: Android-chain artifacts built, AVB-signed under the dev key, and reference-verified host-side; the board owes M1 (unlock/relock)"
echo "FAIRPHONE TARGET GATE ALL GREEN"
