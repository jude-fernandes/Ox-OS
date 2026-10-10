#!/usr/bin/env bash
# Host-side verification of the guest-written marker inside the LUKS2 volume.
set -eu
IMG="${1:-/tmp/ox-boot/payload/data.img}"
KEY="$IMG.key"
command -v cryptsetup >/dev/null || exit 1
[ -f "$KEY" ] || { echo "no keyfile for $IMG"; exit 2; }
cryptsetup open "$IMG" ox-verify-data --key-file "$KEY"
MNT=$(mktemp -d)
mount "/dev/mapper/ox-verify-data" "$MNT" || {
    cryptsetup close ox-verify-data; rm -rf "$MNT"; exit 3; }
if [ -f "$MNT/.ox-ready" ]; then
    echo "DATA VERIFY OK: $(cat "$MNT/.ox-ready")"
    rc=0
else
    echo "DATA VERIFY FAIL: marker missing"
    rc=4
fi
umount "$MNT"; cryptsetup close ox-verify-data; rmdir "$MNT"
exit $rc
