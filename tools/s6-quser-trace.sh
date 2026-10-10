#!/usr/bin/env bash
# Trace the arm64 s6-rc-init inside the Ox OS rootfs via qemu-user + host strace.
set -u
R=/tmp/ox-boot/rootfs
Q=/usr/bin/qemu-aarch64-static
cp -f "$Q" "$R/usr/bin/" 2>/dev/null || exit 1
rm -rf "$R/run/service" "$R/run/service.scan"
mkdir -p "$R/run/service.scan"

chroot "$R" "$Q" /usr/bin/s6-svscan /run/service.scan &
SV=$!
i=0
while [ $i -lt 50 ] && [ ! -d "$R/run/service.scan/.s6-svscan" ]; do i=$((i+1)); sleep 0.1; done
echo "== svscan up =="
strace -f -qq -e trace=%file,execve,clone,fork,vfork \
    chroot "$R" "$Q" /usr/bin/s6-rc-init -c /etc/s6-rc/compiled -l /run/service -t 6000 /run/service.scan 2>&1 |
    grep -aE 'ENOENT|ENXIO|EACCES|execve|clone|fork' | grep -av ENOENT.*supervise/lock | grep -av ENOENT.*/log | head -30
echo "== rc done; killing svscan =="
kill "$SV" 2>/dev/null
