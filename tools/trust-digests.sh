#!/usr/bin/env bash
# Host-side digests of the CURRENT attack payload's trust artifacts.
set -eu
P=/tmp/ox-attack/payload
for f in manifest.bin manifest.sig release.pub.raw; do
    if [ -f "$P/$f" ]; then
        printf '%-14s %s\n' "$f" "$(sha256sum "$P/$f" | cut -d' ' -f1)"
    else
        echo "$f MISSING"
    fi
done
# and the pristine copies inside the initramfs staging dir
for f in etc/ox-manifest.bin etc/ox-manifest.sig ox-release.pub; do
    p="$P/initramfs.dir/$f"
    [ -f "$p" ] && printf '%-22s %s\n' "$(basename $f)" \
        "$(sha256sum "$p" | cut -d' ' -f1)"
done
