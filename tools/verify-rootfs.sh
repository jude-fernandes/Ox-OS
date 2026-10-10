#!/bin/sh
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
nix build -L .#rootfs-qemu --no-link 2>&1 | tail -2
R=$(nix eval --raw .#rootfs-qemu)
echo "rootfs: $R"
echo "== key paths =="
ls "$R/bin/busybox" "$R/sbin/ox-init-stage2" "$R/etc/s6-rc/compiled" > /dev/null && echo "busybox + stage2 + compiled DB present"
for b in oxcom oxpaymentsd ox-status inputd powerd; do
    [ -x "$R/usr/bin/$b" ] || { echo "MISSING $b"; exit 1; }
done
echo "all 5 guest daemons installed"
file "$R/usr/bin/oxcom" | head -1
file "$R/usr/bin/s6-svscan" | head -1
echo "ROOTFS OK"
