#!/bin/sh
# Receipts milestone: re-run the (extended) pay gate on the already-built
# payload + kernel. No rebuilds unless the store is empty.
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
sed -i 's/\r$//' targets/qemu-virt-aarch64/run-qemu.sh tools/pay-gate.sh

"$NIX" build -L .#guest-daemons .#kernel-qemu --no-link --print-out-paths > /tmp/ox-nix-paths
K="$(sed -n 2p /tmp/ox-nix-paths)/Image"
"$NIX" build -L .#payload-qemu --no-link --print-out-paths > /tmp/ox-nix-paths2
P="$(sed -n 1p /tmp/ox-nix-paths2)"

rm -rf /tmp/ox-pay-payload && mkdir -p /tmp/ox-pay-payload
cp -r "$P"/. /tmp/ox-pay-payload/
exec bash tools/pay-gate.sh /tmp/ox-pay-payload "$K"
