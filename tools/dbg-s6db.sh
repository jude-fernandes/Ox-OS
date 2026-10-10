#!/bin/sh
# Debug: check whether usb services made it into the compiled s6 db.
set -u
cd /root/oxbuild
P="$(sed -n 1p /tmp/nixout.txt)"
echo "PAYLOAD=$P"
ls -la "$P" 2>/dev/null | head -5
SQ="$P/system.img"
rm -rf /tmp/sysq
mkdir -p /tmp/sysq
unsquashfs -q -d /tmp/sysq "$SQ" >/dev/null 2>&1
echo "--- source dirs matching usb:"
ls /tmp/sysq/etc/s6-rc/source 2>/dev/null | grep usb
echo "--- compiled db entries matching usb:"
ls /tmp/sysq/etc/s6-rc/compiled 2>/dev/null | grep usb
echo "--- contents in db source:"
grep -a usb /tmp/sysq/etc/s6-rc/source/default/contents 2>/dev/null
