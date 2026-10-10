#!/bin/sh
# Eval-check + build the guest primitives (busybox, s6 stack).
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
for f in flake.nix system/s6-stack.nix system/busybox-guest.nix system/rootfs.nix; do
    sed -i 's/\r$//' "$f"
done
nix flake check 2>&1 | tail -3
echo "== busybox-aarch64 =="
nix build -L .#busybox-aarch64
file result/bin/busybox
echo "== s6-stack =="
nix build -L .#s6-stack
file result/bin/s6-svscan
echo "PARTS OK"
