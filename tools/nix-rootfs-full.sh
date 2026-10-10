#!/bin/sh
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
sed -i 's/\r$//' system/rootfs.nix
nix build -L .#rootfs-qemu > /tmp/rootfs-full.log 2>&1 || true
grep -an "Running phase\|find\b\|ERROR\|error\|busybox\|s6-rc" /tmp/rootfs-full.log | head -30
echo ================
sed -n '1,60p' /tmp/rootfs-full.log
