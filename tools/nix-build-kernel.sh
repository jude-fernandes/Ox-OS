#!/bin/sh
# Build the Nix kernel-qemu derivation (long pole).
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
nix build -L .#kernel-qemu
echo "KERNEL NIX BUILD OK: $(readlink result)"
ls -la result/ | head -10
