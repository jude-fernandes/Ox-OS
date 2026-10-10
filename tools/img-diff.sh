#!/usr/bin/env bash
set -eu
A=/tmp/ox-selftest-out/payload/system.img
B=/tmp/ox-selftest-out2/payload/system.img
rm -rf /tmp/ll-a /tmp/ll-b /tmp/c-a /tmp/c-b
unsquashfs -ll "$A" >/tmp/ll-a.txt 2>/dev/null
unsquashfs -ll "$B" >/tmp/ll-b.txt 2>/dev/null
sed -i 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9].*//' /tmp/ll-a.txt /tmp/ll-b.txt
diff /tmp/ll-a.txt /tmp/ll-b.txt | head -12 || true
unsquashfs -d /tmp/c-a -f "$A" >/dev/null 2>&1
unsquashfs -d /tmp/c-b -f "$B" >/dev/null 2>&1
(cd /tmp/c-a && find . -type f -exec sha256sum {} \; | sort -k2) >/tmp/ca.txt
(cd /tmp/c-b && find . -type f -exec sha256sum {} \; | sort -k2) >/tmp/cb.txt
diff /tmp/ca.txt /tmp/cb.txt | head -8 || true
echo LISTDIFF_DONE
