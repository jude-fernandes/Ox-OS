#!/bin/sh
# Build payload+kernel, clone payload, run the gesture gate.
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd /root/oxbuild
"$NIX" build .#payload-qemu .#kernel-qemu --no-link --print-out-paths \
    --option cores 4 --max-jobs 1 \
    2>/tmp/nixerr.txt > /tmp/nixout.txt || { echo "BUILD FAILED"; tail -4 /tmp/nixerr.txt; exit 1; }
P="$(sed -n 1p /tmp/nixout.txt)"
K="$(sed -n 2p /tmp/nixout.txt)/Image"
# R-23 interim: plain-ext4 data.img on the virtual target (LUKS unlock
# is hardware-gated) — see tools/notification-gate-run.sh
rm -rf /tmp/ox-gsg-payload && mkdir -p /tmp/ox-gsg-payload
cp -r "$P"/. /tmp/ox-gsg-payload/
rm -f /tmp/ox-gsg-payload/data.img /tmp/ox-gsg-payload/data.img.key
exec bash tools/gesture-gate.sh /tmp/ox-gsg-payload "$K"
