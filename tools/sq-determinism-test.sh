#!/usr/bin/env bash
# Verify mksquashfs determinism given explicit alphabetical -sort files.
set -eu
cd /tmp
mk() { # rootdir outfile sortfile
    (cd "$1" && find . | sed 's|^\./||' | LC_ALL=C sort | grep -vx '.' |
        sed 's/$/ 0/' > "$3")
    rm -f "$2"
    mksquashfs "$1" "$2" -comp zstd -Xcompression-level 15 \
        -all-time 0 -root-time 0 -mkfs-time 0 \
        -no-exports -no-recovery -quiet -no-progress -processors 1 \
        -sort "$3" >/dev/null
    sha256sum "$2"
}
mk ox-selftest-out/rootfs  /tmp/sqA /tmp/sortA.txt
mk ox-selftest-out/rootfs  /tmp/sqA2 /tmp/sortA2.txt
mk ox-selftest-out2/rootfs /tmp/sqB /tmp/sortB.txt
