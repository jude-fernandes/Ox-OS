#!/usr/bin/env bash
# Re-extract reference af.c without internal.h, then run the AF differential test.
set -eu
cd /tmp
tar -xf cs.tar.xz cryptsetup-2.7.5/lib/luks1/af.c cryptsetup-2.7.5/lib/luks1/af.h 2>/dev/null || true
sed -i '/#include "internal.h"/d' cryptsetup-2.7.5/lib/luks1/af.c
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
gcc -O0 -o /tmp/af-t tools/af-diff-test.c 2>&1 | grep -E ': error' | head -6 || true
/tmp/af-t
