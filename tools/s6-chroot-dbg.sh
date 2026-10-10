#!/usr/bin/env bash
# Register aarch64 binfmt + chroot into the Ox OS rootfs to debug s6 boot natively.
set -u
MAGIC='\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00'
if ! ls /proc/sys/fs/binfmt_misc/ 2>/dev/null | grep -q '^qemu-aarch64$'; then
    printf ':qemu-aarch64:M::%s::/usr/bin/qemu-aarch64-static:\n' "$MAGIC" \
        > /proc/sys/fs/binfmt_misc/register 2>/dev/null || echo "register failed"
fi
ls /proc/sys/fs/binfmt_misc/ | grep -a aarch64 || exit 1

R=/tmp/ox-boot/rootfs
mkdir -p "$R/proc" "$R/dev" "$R/tmp"
mount -t proc proc "$R/proc" 2>/dev/null
cp -f /usr/bin/strace "$R/usr/bin/" 2>/dev/null || { apt-get install -y strace >/dev/null 2>&1; cp -f /usr/bin/strace "$R/usr/bin/"; }
cp -f /usr/bin/qemu-aarch64-static "$R/usr/bin/" 2>/dev/null || true

cat > "$R/tmp/s6dbg.sh" <<'EOF'
#!/bin/sh
export PATH=/usr/bin:/bin:/sbin:/usr/sbin
mkdir -p /run/service.scan
/usr/bin/s6-svscan /run/service.scan &
i=0
while [ $i -lt 50 ] && [ ! -d /run/service.scan/.s6-svscan ]; do i=$((i+1)); sleep 0.1; done
echo "== svscan up =="
strace -f -qq -e trace=%file,execve /usr/bin/s6-rc-init -c /etc/s6-rc/compiled -l /run/service -t 8000 /run/service.scan 2>&1 | grep -E 'ENOENT|ENXIO|execve' | head -20
echo "== rc-init rc above; now plain run =="
rm -rf /run/service* 2>/dev/null
kill %1 2>/dev/null
sleep 0.3
mkdir -p /run/service.scan
/usr/bin/s6-svscan /run/service.scan &
i=0
while [ $i -lt 50 ] && [ ! -d /run/service.scan/.s6-svscan ]; do i=$((i+1)); sleep 0.1; done
/usr/bin/s6-rc-init -c /etc/s6-rc/compiled -l /run/service -t 8000 /run/service.scan
echo "rc-init rc=$?"
/usr/bin/s6-rc -up change default
echo "rc-change rc=$?"
sleep 1
/usr/bin/s6-svstat /run/service/scandir/getty-ttyAMA0 2>/dev/null || ls /run/service/
EOF
chmod +x "$R/tmp/s6dbg.sh"
chroot "$R" /bin/sh /tmp/s6dbg.sh 2>&1 | tail -40
umount "$R/proc" 2>/dev/null
