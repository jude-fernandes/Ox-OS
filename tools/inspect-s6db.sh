#!/bin/sh
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
R=$(nix eval --raw .#rootfs-qemu)
echo "== compiled DB top level =="
ls "$R/etc/s6-rc/compiled/" | head -25
echo "== does source copy have audio-selftest? =="
ls "$R/etc/s6-rc/source/" | head -20
ls "$R/etc/s6-rc/source/audio-selftest" 2>&1 || true
echo "== any audio string anywhere in compiled =="
grep -rl "audio" "$R/etc/s6-rc/compiled/" 2>/dev/null | head -5 || echo "(none)"
echo "== default bundle contents file =="
cat "$R/etc/s6-rc/compiled/default/contents" 2>/dev/null || \
    find "$R/etc/s6-rc/compiled" -name "contents" | head -5
