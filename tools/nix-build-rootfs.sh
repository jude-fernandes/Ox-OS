#!/bin/sh
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
sed -i 's/\r$//' system/rootfs.nix flake.nix
nix build -L .#rootfs-qemu 2>&1 | tail -12
echo "rootfs store path: $(readlink result)"
ls result/
ls result/usr/bin | head -12
