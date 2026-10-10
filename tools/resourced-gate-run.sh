#!/bin/sh
# Build payload+kernel, clone payload, run the resourced gate.
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd /root/oxbuild
"$NIX" build .#payload-qemu .#kernel-qemu --no-link --print-out-paths \
    --option cores 4 --max-jobs 1 \
    2>/tmp/nixerr.txt > /tmp/nixout.txt || { echo "BUILD FAILED"; tail -4 /tmp/nixerr.txt; exit 1; }
P="$(sed -n 1p /tmp/nixout.txt)"
K="$(sed -n 2p /tmp/nixout.txt)/Image"
rm -rf /tmp/ox-resg-payload && mkdir -p /tmp/ox-resg-payload
cp -r "$P"/. /tmp/ox-resg-payload/
exec bash tools/resourced-gate.sh /tmp/ox-resg-payload "$K"
