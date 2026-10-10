#!/bin/sh
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
nix build -L .#rootfs-qemu --no-link > /dev/null 2>&1 || true
R=$(nix eval --raw .#rootfs-qemu)
echo "== ox-init-stage2 shebang =="
head -1 "$R/sbin/ox-init-stage2"
echo "== s6-rc source run shebang =="
head -1 "$R/etc/s6-rc/source/getty-ttyAMA0/run"
echo "== compiled DB run shebang =="
head -1 "$R/etc/s6-rc/compiled/getty-ttyAMA0/run"
grep -r "nix/store" "$R/sbin/ox-init-stage2" && echo "BAD: nix store ref in stage2" || echo "no nix/store refs in stage2 OK"
