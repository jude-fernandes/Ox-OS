#!/bin/sh
# Build payload+kernel, clone payload, run the MT-call gate.
# NOTE: build from the WSL-native tree (/root/oxbuild).
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd /root/oxbuild
"$NIX" build .#payload-qemu .#kernel-qemu --no-link --print-out-paths \
    --option cores 4 --max-jobs 1 \
    2>/tmp/nixerr.txt > /tmp/nixout.txt || { echo "BUILD FAILED"; tail -6 /tmp/nixerr.txt; exit 1; }
P="$(sed -n 1p /tmp/nixout.txt)"
K="$(sed -n 2p /tmp/nixout.txt)/Image"
rm -rf /tmp/ox-mtgate-payload && mkdir -p /tmp/ox-mtgate-payload
cp -r "$P"/. /tmp/ox-mtgate-payload/
rm -f /tmp/ox-mtgate-payload/data.img /tmp/ox-mtgate-payload/data.img.key
exec bash tools/mt-call-gate.sh /tmp/ox-mtgate-payload "$K"
