#!/bin/sh
# diagnostic: which ox-init.c is in which store source snapshot
echo "=== newest 3 snapshots:"
ls -dt /nix/store/*-source 2>/dev/null | head -3 | while read -r s; do
    echo "SNAP $s"
    grep -c 'sysfs read' "$s/initramfs/ox-init.c" 2>/dev/null | sed 's/^/  sysfs-read-occurrences: /'
    grep -n 'snprintf(sysdev' "$s/initramfs/ox-init.c" 2>/dev/null | head -2
done
echo "=== the rootfs drv's snapshot:"
grep -o '/nix/store/[a-z0-9]*-source' /nix/store/23vvpzd2fhmbn8i9a6sk80hn1w5z4zwy-ox-rootfs-qemu-0.1.0-phase1.drv 2>/dev/null | sort -u | while read -r s; do
    echo "ROOTFS-SRC $s"
    ls "$s/system/s6-rc-source/slot-confirm/" 2>/dev/null | tr '\n' ' '
    echo
    grep -c 'sysfs read' "$s/initramfs/ox-init.c" 2>/dev/null
done
