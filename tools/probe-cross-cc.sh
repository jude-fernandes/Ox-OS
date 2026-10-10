#!/bin/sh
# Probe the musl cross cc-wrapper: which libc paths does it inject?
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"

echo "== is musl 1.2.6 realized? =="
nix path-info nixpkgs#pkgsCross.aarch64-multiplatform-musl.musl 2>&1 | head -2 || true

CCBIN=$(nix build --no-link --print-out-paths ".#pkgsCross.aarch64-multiplatform-musl.stdenv.cc" 2>/dev/null | head -1)
echo "cc wrapper: $CCBIN"
echo "== -L/-B flags in wrapper =="
grep -oE '\-L ?/nix/store/[^ "]*|\-B ?/nix/store/[^ "]*' \
    "$CCBIN/bin/aarch64-unknown-linux-musl-gcc" | head -10 || echo "(none)"
echo "== hello static link test =="
printf 'int main(void){return 0;}\n' > /tmp/t.c
PATH="$CCBIN/bin:$PATH" aarch64-unknown-linux-musl-gcc -static /tmp/t.c -o /tmp/t \
    2>&1 | head -5 || true
file /tmp/t 2>/dev/null || echo "no binary produced"
