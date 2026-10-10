#!/bin/sh
# Build payload+kernel, clone payload, run the sms-receive gate.
# NOTE: build from the WSL-native tree (/root/oxbuild).
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd /root/oxbuild
"$NIX" build .#payload-qemu .#kernel-qemu --no-link --print-out-paths \
    --option cores 4 --max-jobs 1 \
    2>/tmp/nixerr.txt > /tmp/nixout.txt || { echo "BUILD FAILED"; tail -6 /tmp/nixerr.txt; exit 1; }
P="$(sed -n 1p /tmp/nixout.txt)"
K="$(sed -n 2p /tmp/nixout.txt)/Image"
rm -rf /tmp/ox-recvgate-payload && mkdir -p /tmp/ox-recvgate-payload
cp -r "$P"/. /tmp/ox-recvgate-payload/
rm -f /tmp/ox-recvgate-payload/data.img /tmp/ox-recvgate-payload/data.img.key
exec bash tools/sms-recv-gate.sh /tmp/ox-recvgate-payload "$K"
