#!/usr/bin/env bash
# Diff two payload builds to locate reproducibility regressions.
set -u
A=/tmp/ox-selftest-out/payload
B=/tmp/ox-selftest-out2/payload
rm -rf /tmp/rp-a /tmp/rp-b
for pair in "a:$A" "b:$B"; do
    side="${pair%%:*}"; dir="${pair#*:}"
    unsquashfs -d "/tmp/rp-$side" -f "$dir/system.img" >/dev/null 2>&1
done
cd /tmp || exit 1
(cd rp-a && find . -type f -exec sha256sum {} + | sed 's|rp-a||' | sort -k2) >/tmp/ra.txt
(cd rp-b && find . -type f -exec sha256sum {} + | sed 's|rp-b||' | sort -k2) >/tmp/rb.txt
diff /tmp/ra.txt /tmp/rb.txt | head -20
echo "=== meta ==="
cmp -s "$A/cmdline.txt" "$B/cmdline.txt" && echo cmdline same || echo cmdline DIFF
