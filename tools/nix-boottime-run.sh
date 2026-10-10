#!/bin/sh
# Run the boot-time budget gate against the current Nix-built payload.
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
sed -i 's/\r$//' tools/boottime-gate.sh tools/boottime-parse.py
nix build -L .#payload-qemu .#kernel-qemu --no-link --print-out-paths > /tmp/ox-nix-paths
P=$(sed -n 1p /tmp/ox-nix-paths)
K=$(sed -n 2p /tmp/ox-nix-paths)
echo "[boottime] payload: $P"
echo "[boottime] kernel:  $K"
rm -rf /tmp/ox-bt-payload && mkdir -p /tmp/ox-bt-payload
cp -r "$P"/. /tmp/ox-bt-payload/
bash tools/boottime-gate.sh /tmp/ox-bt-payload "$K/Image" 3
