#!/usr/bin/env bash
set -eu
rm -rf /tmp/irdchk && mkdir /tmp/irdchk
cd /tmp/irdchk
zcat /tmp/ox-attack/payload/initramfs.img | cpio -idm --quiet
for f in etc/ox-manifest.bin etc/ox-manifest.sig ox-release.pub; do
    if cmp -s "$f" "/tmp/ox-attack/payload/initramfs.dir/$f"; then
        echo "SAME $f"
    else
        echo "DIFF $f"
        ls -la "$f" "/tmp/ox-attack/payload/initramfs.dir/$f" || true
    fi
done
