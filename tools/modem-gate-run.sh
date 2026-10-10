#!/bin/sh
# Build payload+kernel, clone payload, run the modem transport gate.
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd /root/oxbuild
"$NIX" build .#payload-qemu .#kernel-qemu --no-link --print-out-paths \
    --option cores 4 --max-jobs 1 \
    2>/tmp/nixerr.txt > /tmp/nixout.txt || { echo "BUILD FAILED"; tail -4 /tmp/nixerr.txt; exit 1; }
P="$(sed -n 1p /tmp/nixout.txt)"
K="$(sed -n 2p /tmp/nixout.txt)/Image"
rm -rf /tmp/ox-modemg-payload && mkdir -p /tmp/ox-modemg-payload
cp -r "$P"/. /tmp/ox-modemg-payload/
# The payload ships a LUKS-formatted data.img; without the unlock step
# this boot cannot mount it, /data stays read-only and permstored
# correctly refuses to serve unsavable grants. Force the fresh plain
# ext4 path (fleet convention: bt/gnss runners do the same).
rm -f /tmp/ox-modemg-payload/data.img /tmp/ox-modemg-payload/data.img.key
exec bash tools/modem-transport-gate.sh /tmp/ox-modemg-payload "$K"
