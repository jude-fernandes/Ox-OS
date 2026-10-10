#!/bin/sh
set -eu
OX="/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"

echo "== env the previous run lacked =="
command -v busybox || echo "no busybox on PATH"
ls -la /tmp/ox-aarch64/busybox 2>/dev/null || echo "no /tmp/ox-aarch64/busybox"
ls /tmp/ox-gfx/rootfs 2>/dev/null | head -5
echo "rootfs file count: $(find /tmp/ox-gfx/rootfs -type f 2>/dev/null | wc -l)"

echo "== rerun dev-pipeline unfiltered =="
OX_BUSYBOX=/tmp/ox-aarch64/busybox sh "$OX/tools/dev-pipeline.sh" /tmp/ox-gfx 2>&1 | tail -20
