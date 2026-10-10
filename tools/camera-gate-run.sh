#!/bin/sh
# Build payload+kernel (kernel = long pole on camera-fragment changes),
# clone payload, run the camera gate.
# NOTE: build from the WSL-native tree (/root/oxbuild) — the /mnt/c
# 9p tree can serve stale file content after VM restarts.
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd /root/oxbuild
"$NIX" build .#payload-qemu .#kernel-qemu --no-link --print-out-paths \
    --option cores 4 --max-jobs 1 \
    2>/tmp/nixerr.txt > /tmp/nixout.txt || { echo "BUILD FAILED"; tail -6 /tmp/nixerr.txt; exit 1; }
P="$(sed -n 1p /tmp/nixout.txt)"
K="$(sed -n 2p /tmp/nixout.txt)/Image"
rm -rf /tmp/ox-cameragate-payload && mkdir -p /tmp/ox-cameragate-payload
cp -r "$P"/. /tmp/ox-cameragate-payload/
rm -f /tmp/ox-cameragate-payload/data.img /tmp/ox-cameragate-payload/data.img.key
exec bash tools/camera-gate.sh /tmp/ox-cameragate-payload "$K"
