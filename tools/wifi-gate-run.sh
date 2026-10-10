#!/bin/sh
# Build payload+kernel (kernel = long pole on wireless-fragment
# changes), clone payload, run the wifi gate.
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd /root/oxbuild
"$NIX" build .#payload-qemu .#kernel-qemu --no-link --print-out-paths \
    --option cores 4 --max-jobs 1 \
    2>/tmp/nixerr.txt > /tmp/nixout.txt || { echo "BUILD FAILED"; tail -6 /tmp/nixerr.txt; exit 1; }
P="$(sed -n 1p /tmp/nixout.txt)"
K="$(sed -n 2p /tmp/nixout.txt)/Image"
rm -rf /tmp/ox-wfg-payload && mkdir -p /tmp/ox-wfg-payload
cp -r "$P"/. /tmp/ox-wfg-payload/
rm -f /tmp/ox-wfg-payload/data.img /tmp/ox-wfg-payload/data.img.key
exec bash tools/wifi-gate.sh /tmp/ox-wfg-payload "$K"
