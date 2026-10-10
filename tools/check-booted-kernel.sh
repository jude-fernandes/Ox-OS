#!/bin/sh
set -eu
KPATH="$(sed -n 2p /tmp/ox-nix-paths)/Image"
echo "kernel path: $KPATH"
ls -la "$KPATH"
strings "$KPATH" | grep -m1 'Linux version'
for s in "xts-aes-neonbs" "xts(aes)" "ecb(aes)"; do
    printf '%-18s %s\n' "$s" "$(strings "$KPATH" | grep -c "$s")"
done
