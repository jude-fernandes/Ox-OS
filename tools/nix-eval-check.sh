#!/bin/sh
# Evaluate-check the flake and (optionally) build a single package in the
# background: usage: nix-eval-check.sh [PACKAGE]
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
sed -i 's/\r$//' flake.nix kernel/kernel.nix system/rootfs.nix \
    targets/qemu-virt-aarch64/payload.nix 2>/dev/null || true

nix flake check 2>&1 | tail -3
echo "== eval =="
nix eval .#kernel-qemu.drvPath
if [ $# -ge 1 ]; then
    echo "== building $1 =="
    exec nix build -L ".$1"
fi
