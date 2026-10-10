#!/bin/sh
# Build payload+kernel, clone payload, run the messaging-app gate.
# NOTE: build from the WSL-native tree (/root/oxbuild).
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd /root/oxbuild
"$NIX" build .#payload-qemu .#kernel-qemu --no-link --print-out-paths \
    --option cores 4 --max-jobs 1 \
    2>/tmp/nixerr.txt > /tmp/nixout.txt || { echo "BUILD FAILED"; tail -6 /tmp/nixerr.txt; exit 1; }
P="$(sed -n 1p /tmp/nixout.txt)"
K="$(sed -n 2p /tmp/nixout.txt)/Image"
rm -rf /tmp/ox-smsgate-payload && mkdir -p /tmp/ox-smsgate-payload
cp -r "$P"/. /tmp/ox-smsgate-payload/
rm -f /tmp/ox-smsgate-payload/data.img /tmp/ox-smsgate-payload/data.img.key
exec bash tools/sms-app-gate.sh /tmp/ox-smsgate-payload "$K"
