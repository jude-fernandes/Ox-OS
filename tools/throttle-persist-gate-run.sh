#!/bin/sh
# Throttle gate runner: builds the CURRENT tree first (chunk-60 lesson:
# a hardcoded store path rots when GC reaps it and the gate dies in
# seconds), then boots a fresh payload clone with a clean data volume.
set -eu
cd /root/oxbuild
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
"$NIX" build .#payload-qemu .#kernel-qemu --no-link --print-out-paths --offline \
    --option cores 4 --max-jobs 1 \
    2>/tmp/nixerr.txt > /tmp/nixout.txt || { echo "BUILD FAILED"; tail -6 /tmp/nixerr.txt; exit 1; }
P="$(sed -n 1p /tmp/nixout.txt)"
K="$(sed -n 2p /tmp/nixout.txt)/Image"
echo "PAYLOAD $P"
s6_integrity_guard "$P"
pkill -f "[q]emu-system-aarch64" >/dev/null 2>&1 || true
sleep 2
rm -rf /tmp/ox-tp-payload && mkdir -p /tmp/ox-tp-payload
cp -r "$P"/. /tmp/ox-tp-payload/
rm -f /tmp/ox-tp-payload/data.img /tmp/ox-tp-payload/data.img.key
exec bash tools/throttle-persist-gate.sh /tmp/ox-tp-payload "$K"
