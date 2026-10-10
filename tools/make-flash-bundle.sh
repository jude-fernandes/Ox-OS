#!/bin/sh
# Assemble a self-contained flash bundle per device: prebuilt image dir
# + the flash script + its tools, laid out so ox-flash.sh's relative
# tool paths resolve. Result: flashing a device needs this tarball, a
# Windows/Linux host with an SD card / fastboot — NOT the nix build.
#
# usage: tools/make-flash-bundle.sh [target ...]
#   targets: pinephone-pro fairphone5 oneplus9rt oneplus10pro
#            (default: all four)
# output: ox-flash-bundle-<date>.tar.gz in the current directory
set -eu
N=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd /root/oxbuild

TARGETS="$@"
[ $# -gt 0 ] || TARGETS="pinephone-pro fairphone5 oneplus9rt oneplus10pro"

ATTRS=""
for T in $TARGETS; do
    ATTRS="$ATTRS .#image-$T"
done
# --print-out-paths order matches the attribute order given
$N build $ATTRS --no-link --print-out-paths > /tmp/bundle-nixout.txt
echo "store paths:"; cat /tmp/bundle-nixout.txt

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
i=0
for T in $TARGETS; do
    i=$((i + 1))
    SRC=$(sed -n "${i}p" /tmp/bundle-nixout.txt)
    mkdir -p "$WORK/bundle/images/$T" "$WORK/bundle/targets/$T"
    cp -rL "$SRC"/. "$WORK/bundle/images/$T/"
    cp "targets/$T/ox-flash.sh" "$WORK/bundle/targets/$T/" 2>/dev/null || true
    cp "targets/$T/ox-update.sh" "$WORK/bundle/targets/$T/" 2>/dev/null || true
done
mkdir -p "$WORK/bundle/tools"
cp tools/ox-slotmeta.py tools/ox-mkfit.py tools/ox-mkdtbo.py \
   tools/uboot-control-dtb.py "$WORK/bundle/tools/" 2>/dev/null || true
cp tools/aosp/avbtool.py "$WORK/bundle/tools/aosp-avbtool.py" 2>/dev/null || true

cat > "$WORK/bundle/FLASH-README.txt" <<'EOF'
Ox OS flash bundle — prebuilt artifacts, no build system needed.

Layout: images/<device>/  — the built artifact set (idbloader/u-boot,
         boot images, system.img + verity tree, metadata key, digests)
        targets/<device>/ox-flash.sh — the write path
        tools/ — helpers the flash script calls

Per device (see images/<device>/README-FLASH.txt first):
  PinePhone Pro: write to an SD card or eMMC module:
      sudo bash targets/pinephone-pro/ox-flash.sh /dev/<sdX> images/pinephone-pro
      (<sdX> = the WHOLE device, e.g. /dev/sdb — double-check with lsblk;
       the script dd's firmware at fixed offsets and partitions the rest)
  Fairphone 5 / OnePlus 9RT / 10 Pro: Android-slot devices — flash via
      fastboot using the images in images/<device>/ (boot.img /
      vendor_boot.img / vbmeta / dtbo), then follow
      targets/<device>/README-FLASH.txt.

The data.img.key in the bundle is the documented DEV key (risk R-22).
Serial console: 1500000 8N1 (PinePhone Pro) / 115200 (Qualcomm targets).
Report the first 60 serial lines on any boot attempt — bring-up starts
there.
EOF

STAMP=$(date -u +%Y%m%d)
tar czf "ox-flash-bundle-$STAMP.tar.gz" -C "$WORK" bundle
ls -la "ox-flash-bundle-$STAMP.tar.gz"
echo "bundle ready: ox-flash-bundle-$STAMP.tar.gz"
