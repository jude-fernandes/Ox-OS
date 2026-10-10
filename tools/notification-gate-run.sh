#!/bin/sh
# Build payload+kernel, clone payload, run the notification/permission
# gate (two boots: flow + reboot persistence).
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd /root/oxbuild
"$NIX" build .#payload-qemu .#kernel-qemu --no-link --print-out-paths \
    --option cores 4 --max-jobs 1 \
    2>/tmp/nixerr.txt > /tmp/nixout.txt || { echo "BUILD FAILED"; tail -4 /tmp/nixerr.txt; exit 1; }
P="$(sed -n 1p /tmp/nixout.txt)"
K="$(sed -n 2p /tmp/nixout.txt)/Image"
rm -rf /tmp/ox-notifg-payload && mkdir -p /tmp/ox-notifg-payload
cp -r "$P"/. /tmp/ox-notifg-payload/
# R-23 interim: the virtual target cannot unlock a LUKS2 data volume
# in-guest (risk register R-23), so this gate runs the plain-ext4 data
# image path — remove the key + image and run-qemu formats ext4.
# Hardware targets keep the LUKS2 volume.
rm -f /tmp/ox-notifg-payload/data.img /tmp/ox-notifg-payload/data.img.key
exec bash tools/notification-gate.sh /tmp/ox-notifg-payload "$K"
