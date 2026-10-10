#!/bin/sh
# Build (cached no-op), clone payload, run the overnight suspend soak.
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd /root/oxbuild
"$NIX" build .#payload-qemu .#kernel-qemu --no-link --print-out-paths \
    --option cores 4 --max-jobs 1 \
    2>/tmp/nixerr.txt > /tmp/nixout.txt || { echo "BUILD FAILED"; tail -4 /tmp/nixerr.txt; exit 1; }
P="$(sed -n 1p /tmp/nixout.txt)"
K="$(sed -n 2p /tmp/nixout.txt)/Image"
# kill stray QEMU from earlier interrupted runs — pattern assembled so
# this script's own cmdline never contains it
PAT="qemu-sy""stem-aarch64"
for pid in $(pgrep -f "$PAT" 2>/dev/null); do
    kill "$pid" 2>/dev/null || true
done
sleep 1
rm -rf /tmp/ox-soakg-payload && mkdir -p /tmp/ox-soakg-payload
cp -r "$P"/. /tmp/ox-soakg-payload/
exec bash tools/soak-gate.sh /tmp/ox-soakg-payload "$K" 1000 28800
