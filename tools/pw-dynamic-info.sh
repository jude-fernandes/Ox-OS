#!/bin/sh
set -eu
R=/nix/store/qlip7b41y6pawf267cfmg0x86fj80raf-ox-rootfs-qemu-0.1.0-phase1
PW="$(ls -d "$R"/nix/store/*pipewire-aarch64* | head -1)"
RE="$(command -v readelf || echo /usr/bin/readelf)"
echo "== program headers (INTERP) =="
"$RE" -l "$PW/bin/pw-cli" | sed -n '/INTERP/,+1p'
echo "== dynamic (rpath/needed) =="
"$RE" -d "$PW/bin/pw-cli" | grep -E 'RPATH|RUNPATH|NEEDED|FLAGS' | head -12
