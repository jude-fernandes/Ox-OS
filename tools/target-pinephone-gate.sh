#!/bin/sh
# PinePhone Pro target gate (chunk 72) — HOST-SIDE, no board needed.
# Asserts that every stage the board would boot exists, is well-formed,
# and verifies cryptographically where host tools allow:
#   FIT structure + signature properties + extract-and-hash the kernel
#   out of the SIGNED ox.itb; the fit-dev public key present in the
#   keyed control DTB; arm64 kernel magic; board compatible strings;
#   U-Boot stages well-formed; the system slot verifies against its
#   dm-verity hash image (THE rootfs the 16-gate suite proves).
# The board itself remains for electrical bring-up (BRINGUP M1/M2).
# usage: target-pinephone-gate.sh IMAGE_DIR
set -eu
IMG="$1"
say() { printf '[ox-ppp] %s\n' "$*"; }
fail() { printf '[ox-ppp] FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf '[ox-ppp] ok: %s\n' "$*"; }

TOOLS="$(cd "$(dirname "$0")" && pwd)"

say "checking artifact set in $IMG"
for f in ox.itb Image rk3399.dtb initramfs.cpio.gz boot.sha256 boot.txt \
         control-keyed.dtb u-boot.itb idbloader.img system.img system.hash.img; do
    [ -f "$IMG/$f" ] || fail "missing artifact: $f"
done
ok "all 11 artifacts present"

# 1. manifest hashes still true
( cd "$IMG" && sha256sum -c boot.sha256 >/dev/null 2>&1 ) \
    || fail "boot.sha256 manifest does not verify"
ok "raw triple hashes match boot.sha256"

# 2. the kernel is an arm64 boot Image (magic at offset 0x38)
MAGIC=$(od -A n -t x1 -j 56 -N 4 "$IMG/Image" | tr -d ' \n')
[ "$MAGIC" = "41524d64" ] || fail "Image magic $MAGIC != ARMd (not an arm64 boot Image)"
ok "Image is an arm64 boot Image (magic ARMd at 0x38)"

# 3. the DTB is the PinePhone Pro board
dtc -I dtb -O dts "$IMG/rk3399.dtb" > /tmp/ox-ppp-dts.txt 2>/dev/null \
    || fail "rk3399.dtb does not decompile"
grep -q "rockchip,rk3399" /tmp/ox-ppp-dts.txt || fail "dtb lacks rockchip,rk3399 compatible"
grep -q "pine64,pinephone-pro" /tmp/ox-ppp-dts.txt || fail "dtb lacks pine64,pinephone-pro compatible"
ok "dtb compatible: rockchip,rk3399 + pine64,pinephone-pro"

# 4. FIT structure: kernel/ramdisk/fdt/conf all present
dumpimage -l "$IMG/ox.itb" > /tmp/ox-ppp-fit.txt 2>/dev/null || fail "ox.itb does not parse"
for node in kernel-1 ramdisk-1 fdt-1 conf-1; do
    grep -q "$node" /tmp/ox-ppp-fit.txt || fail "FIT lacks $node"
done
ok "FIT lists kernel-1 ramdisk-1 fdt-1 conf-1"

# 5. the FIT is SIGNED with the dev key (the signature node lives on the
#    configuration and covers kernel+ramdisk+fdt; U-Boot's enforcement
#    comes from the control-DTB key being required — checked below)
grep -q "fit-dev" /tmp/ox-ppp-fit.txt || fail "FIT listing lacks the fit-dev signature (unsigned FIT?)"
grep -q "rsa2048" /tmp/ox-ppp-fit.txt || fail "FIT signature is not rsa2048"
grep -q "Sign value" /tmp/ox-ppp-fit.txt || fail "FIT signature carries no Sign value"
ok "FIT signature: sha256,rsa2048 by fit-dev (Sign value present)"

# 6. data-integrity: extract the kernel FROM the signed FIT and compare
#    with the source Image — raw (old dumpimage: position 0) or, with
#    OX_FIT_GZIP, the embedded node is gzipped: decompress then compare
dumpimage -T flat_dt -p 0 -o /tmp/ox-ppp-kernel.bin "$IMG/ox.itb" 2>/dev/null \
    || fail "cannot extract the FIT kernel image"
[ -f /tmp/ox-ppp-kernel.bin ] || fail "FIT kernel extraction wrote nothing"
if cmp -s /tmp/ox-ppp-kernel.bin "$IMG/Image"; then
    ok "FIT-embedded kernel byte-identical to the source Image"
elif gzip -dc /tmp/ox-ppp-kernel.bin 2>/dev/null | cmp -s - "$IMG/Image"; then
    ok "FIT-embedded kernel (gzipped) decompresses to the source Image"
else
    fail "FIT-embedded kernel does not match the source Image"
fi

# 7. the control DTB carries the fit-dev public key, marked required for
#    configurations — that is what makes U-Boot ENFORCE the FIT signature
dtc -I dtb -O dts "$IMG/control-keyed.dtb" > /tmp/ox-ppp-ctrl.txt 2>/dev/null \
    || fail "control-keyed.dtb does not decompile"
grep -q "fit-dev" /tmp/ox-ppp-ctrl.txt || fail "control DTB lacks the fit-dev key node"
grep -q "rsa2048" /tmp/ox-ppp-ctrl.txt || fail "control DTB key is not rsa2048"
grep -q 'required = "conf"' /tmp/ox-ppp-ctrl.txt \
    || fail "control DTB key not marked required (U-Boot would not enforce)"
grep -q "rsa,modulus" /tmp/ox-ppp-ctrl.txt || fail "control DTB key carries no public modulus"
ok "control DTB: fit-dev rsa2048 public key, required=conf (U-Boot enforces ox.itb)"

# 8. U-Boot stages well-formed
FMAGIC=$(od -A n -t x1 -N 4 "$IMG/u-boot.itb" | tr -d ' \n')
[ "$FMAGIC" = "d00dfeed" ] || fail "u-boot.itb lacks the FIT magic"
IDBSZ=$(stat -c %s "$IMG/idbloader.img")
[ "$IDBSZ" -gt 65536 ] || fail "idbloader.img suspiciously small ($IDBSZ)"
ok "u-boot.itb is a FIT; idbloader.img $IDBSZ bytes"

# 9. the system slot verifies against its dm-verity tree — THE rootfs
#    the whole 16-gate suite proves on the virtual target (the
#    verify-host.sh pattern: digest.env carries hash+salt)
[ -f "$IMG/digest.env" ] || fail "digest.env missing (verity digest not shipped)"
. "$IMG/digest.env"
[ -n "${OX_ROOT_HASH:-}" ] && [ -n "${OX_SALT:-}" ] \
    || fail "digest.env lacks OX_ROOT_HASH/OX_SALT"
veritysetup verify --no-superblock --salt="$OX_SALT" \
    "$IMG/system.img" "$IMG/system.hash.img" "$OX_ROOT_HASH" \
    || fail "dm-verity verification failed"
ok "system slot: dm-verity tree verifies (root hash ${OX_ROOT_HASH:0:16}...)"

# 10. layout sanity against BRINGUP.md partition sizes
for sz_spec in "ox.itb 67108864" "initramfs.cpio.gz 67108864" "system.img 3221225472"; do
    f=${sz_spec%% *}; max=${sz_spec##* }
    SZ=$(stat -c %s "$IMG/$f")
    [ "$SZ" -le "$max" ] || fail "$f is $SZ bytes, exceeds its partition ($max)"
done
ok "artifacts fit their BRINGUP.md partitions (boot 64M, system 3G)"

say "ALL GREEN — pinephone-pro target: every boot stage built, structured, and verified host-side; the board remains for M1/M2"
echo "PINEPHONE TARGET GATE ALL GREEN"
