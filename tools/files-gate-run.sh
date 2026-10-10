#!/bin/sh
# Build payload+kernel, clone payload, run the Files gate.
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
rm -rf /tmp/ox-filesg-payload && mkdir -p /tmp/ox-filesg-payload
cp -r "$P"/. /tmp/ox-filesg-payload/
rm -f /tmp/ox-filesg-payload/data.img /tmp/ox-filesg-payload/data.img.key
exec bash tools/files-gate.sh /tmp/ox-filesg-payload "$K"
