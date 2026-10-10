#!/bin/sh
# Can the (already-built) GNU aarch64 cross cc-wrapper link statically?
# build-s6-stack.sh used exactly this: CC="aarch64-linux-gnu-gcc -static -s".
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"

CCBIN=$(nix eval --raw nixpkgs#pkgsCross.aarch64-multiplatform.stdenv.cc 2>/dev/null)
echo "gnu cross cc wrapper: $CCBIN"
printf 'int main(void){return 0;}\n' > /tmp/t.c
PATH="$CCBIN/bin:$PATH" aarch64-unknown-linux-gnu-gcc -static -s /tmp/t.c -o /tmp/t-gnu 2>&1 | head -5 || true
file /tmp/t-gnu 2>/dev/null || echo "gnu: no binary produced"

echo "== musl inside gnu wrapper closure (for reference) =="
nix-store -qR "$CCBIN" 2>/dev/null | grep -i musl | head -3 || echo "(no musl)"
