#!/bin/sh
# Build payload+kernel, clone payload, run the negative-matrix gate.
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
rm -rf /tmp/ox-nmg-payload && mkdir -p /tmp/ox-nmg-payload
cp -r "$P"/. /tmp/ox-nmg-payload/
rm -f /tmp/ox-nmg-payload/data.img /tmp/ox-nmg-payload/data.img.key
exec bash tools/negative-matrix-gate.sh /tmp/ox-nmg-payload "$K"
