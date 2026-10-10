#!/usr/bin/env bash
# Fetch remaining orlp/ed25519 files with explicit per-file status.
set -u
DIR="/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/initramfs/ed25519"
cd "$DIR"
for f in ed25519.c fe.h fe.c ge.h ge.c precomp_data.h sc.h sc.c; do
    if [ -s "$f" ]; then echo "have  $f"; continue; fi
    if curl -fsSL --retry 3 -o "$f" \
        "https://raw.githubusercontent.com/orlp/ed25519/master/src/$f"; then
        echo "ok    $f ($(wc -c <"$f") bytes)"
    else
        echo "FAIL  $f"
    fi
done
