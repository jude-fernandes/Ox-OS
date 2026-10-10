#!/bin/sh
# Lock-shield gate runner: builds the CURRENT tree first (the gate
# proves the chunk-59 code, whatever the sweep last built), then boots
# a fresh payload clone with a clean data volume.
set -eu
cd /root/oxbuild
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
"$NIX" build .#payload-qemu .#kernel-qemu --no-link --print-out-paths \
    --option cores 4 --max-jobs 1 \
    2>/tmp/nixerr.txt > /tmp/nixout.txt || { echo "BUILD FAILED"; tail -6 /tmp/nixerr.txt; exit 1; }
P="$(sed -n 1p /tmp/nixout.txt)"
K="$(sed -n 2p /tmp/nixout.txt)/Image"
echo "PAYLOAD $P"
s6_integrity_guard "$P"
pkill -f '[q]emu-system-aarch64' >/dev/null 2>&1 || true
sleep 2
rm -rf /tmp/ox-ls-payload && mkdir -p /tmp/ox-ls-payload
cp -r "$P"/. /tmp/ox-ls-payload/
rm -f /tmp/ox-ls-payload/data.img /tmp/ox-ls-payload/data.img.key
exec bash tools/lock-shield-gate.sh /tmp/ox-ls-payload "$K"
