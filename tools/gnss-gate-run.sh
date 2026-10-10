#!/bin/sh
# Build payload+kernel, clone payload, run the gnss gate.
# NOTE: build from the WSL-native tree (/root/oxbuild) — the /mnt/c
# 9p tree can serve stale file content after VM restarts, which
# resurrects dead drv hashes.
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd /root/oxbuild
"$NIX" build .#payload-qemu .#kernel-qemu --no-link --print-out-paths \
    --option cores 4 --max-jobs 1 \
    2>/tmp/nixerr.txt > /tmp/nixout.txt || { echo "BUILD FAILED"; tail -6 /tmp/nixerr.txt; exit 1; }
P="$(sed -n 1p /tmp/nixout.txt)"
K="$(sed -n 2p /tmp/nixout.txt)/Image"
rm -rf /tmp/ox-gnssgate-payload && mkdir -p /tmp/ox-gnssgate-payload
cp -r "$P"/. /tmp/ox-gnssgate-payload/
rm -f /tmp/ox-gnssgate-payload/data.img /tmp/ox-gnssgate-payload/data.img.key
exec bash tools/gnss-gate.sh /tmp/ox-gnssgate-payload "$K"
