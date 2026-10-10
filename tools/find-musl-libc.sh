#!/bin/sh
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
echo "== musl out path =="
nix eval --raw ".#pkgsCross.aarch64-multiplatform-musl.musl" 2>/dev/null || \
  nix eval --raw nixpkgs#pkgsCross.aarch64-multiplatform-musl.musl 2>/dev/null || true
echo
echo "== libc.a present? =="
for d in /nix/store/*musl-aarch64-unknown-linux-musl-1.2.5; do
    if [ -d "$d/lib" ]; then
        ls "$d/lib" | grep -E "^libc\.(a|so)" | while read -r f; do
            echo "$d/lib/$f"
        done
    fi
done
echo "== wrapper libc attr =="
nix eval --raw ".#pkgsCross.aarch64-multiplatform-musl.stdenv.cc.libc" 2>/dev/null || echo "(no cc.libc attr)"
echo
