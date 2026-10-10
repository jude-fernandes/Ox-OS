#!/bin/sh
set -eu
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
KPATH="$(sed -n 2p /tmp/ox-nix-paths)/Image"
echo "kernel: $KPATH"
for s in "xts-aes-neonbs" "ecb(aes)" "xts(aes)" "xts(aes)-neonbs" "ecb-aes-neonbs"; do
    printf '%-20s %s\n' "$s" "$(strings "$KPATH" | grep -c "$s")"
done
