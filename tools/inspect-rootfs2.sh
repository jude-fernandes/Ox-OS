#!/bin/sh
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
echo "== all recent rootfs store paths =="
ls -dt /nix/store/*ox-rootfs-qemu* 2>/dev/null | head -4
R=$(nix build -L .#rootfs-qemu --no-link --print-out-paths 2>/dev/null | head -1)
echo "== built rootfs: $R =="
ls "$R"
echo "== etc/s6-rc =="
ls "$R/etc/s6-rc" 2>&1 || true
echo "== compiled =="
ls "$R/etc/s6-rc/compiled" 2>&1 | head -20
echo "== source =="
ls "$R/etc/s6-rc/source" 2>&1 | head -12
