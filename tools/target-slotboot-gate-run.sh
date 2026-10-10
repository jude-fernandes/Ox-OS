#!/bin/sh
# Build the PinePhone Pro image set + the qemu kernel/initramfs (the
# guest that boots the flashed A/B layout) and run the slot-boot gate.
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd /root/oxbuild
"$NIX" build .#image-pinephone-pro .#kernel-qemu .#payload-qemu \
    --no-link --print-out-paths \
    --option cores 4 --max-jobs 1 \
    2>/tmp/nixerr.txt > /tmp/nixout.txt || { echo "BUILD FAILED"; tail -8 /tmp/nixerr.txt; exit 1; }
PPP="$(sed -n 1p /tmp/nixout.txt)"
KQ="$(sed -n 2p /tmp/nixout.txt)"
PQ="$(sed -n 3p /tmp/nixout.txt)"
bash tools/gc-keep-current.sh >/dev/null 2>&1 || true
exec bash tools/target-slotboot-gate.sh "$PPP" "$KQ/Image" "$PQ/initramfs.img"
