#!/bin/sh
# Build payload+kernel (kernel = long pole on BT-fragment changes),
# clone payload, run the bt gate.
# NOTE: build from the WSL-native tree (/root/oxbuild) — the /mnt/c
# 9p tree can serve stale file content after VM restarts, which
# resurrects dead drv hashes (seen: broken oxwifid rebuild attempts).
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd /root/oxbuild
"$NIX" build .#payload-qemu .#kernel-qemu --no-link --print-out-paths \
    --option cores 4 --max-jobs 1 \
    2>/tmp/nixerr.txt > /tmp/nixout.txt || { echo "BUILD FAILED"; tail -6 /tmp/nixerr.txt; exit 1; }
P="$(sed -n 1p /tmp/nixout.txt)"
K="$(sed -n 2p /tmp/nixout.txt)/Image"
rm -rf /tmp/ox-btg-payload && mkdir -p /tmp/ox-btg-payload
cp -r "$P"/. /tmp/ox-btg-payload/
rm -f /tmp/ox-btg-payload/data.img /tmp/ox-btg-payload/data.img.key
exec bash tools/bt-gate.sh /tmp/ox-btg-payload "$K"
