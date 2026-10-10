#!/bin/sh
# Build payload+kernel, clone payload, run the shell gate.
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
rm -rf /tmp/ox-shg-payload && mkdir -p /tmp/ox-shg-payload
cp -r "$P"/. /tmp/ox-shg-payload/
rm -f /tmp/ox-shg-payload/data.img /tmp/ox-shg-payload/data.img.key
exec bash tools/shell-gate.sh /tmp/ox-shg-payload "$K"
