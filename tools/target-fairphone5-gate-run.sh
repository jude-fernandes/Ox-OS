#!/bin/sh
# Build the Fairphone 5 image set (Android boot image v4 + dtbo + AVB
# vbmeta + slot images) and run the GENERIC Android-chain gate (chunk
# 75 generalization; the chunk-73 target-fairphone5-gate.sh remains as
# the FP5-specific record). gc-roots on success.
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd /root/oxbuild
"$NIX" build .#image-fairphone5 --no-link --print-out-paths \
    --option cores 4 --max-jobs 1 \
    2>/tmp/nixerr.txt > /tmp/nixout.txt || { echo "BUILD FAILED"; tail -8 /tmp/nixerr.txt; exit 1; }
I="$(sed -n 1p /tmp/nixout.txt)"
bash tools/gc-keep-current.sh >/dev/null 2>&1 || true
exec bash tools/target-android-gate.sh "$I" fairphone5
