#!/bin/sh
# Chunk C verification: pipewire closure landed in the rootfs correctly.
set -eu
R=/nix/store/qlip7b41y6pawf267cfmg0x86fj80raf-ox-rootfs-qemu-0.1.0-phase1
echo "== /nix/store paths in rootfs =="
ls "$R/nix/store" | wc -l
echo "== pipewire out present =="
ls -d "$R"/nix/store/*pipewire-aarch64* 2>/dev/null | head -2
echo "== bin symlinks =="
ls -la "$R/usr/bin/pw-cli" "$R/usr/bin/pw-play" 2>/dev/null
echo "== ELF interpreter of pw-cli resolves in-guest =="
INTERP=$(head -c 200 "$R"/nix/store/*pipewire-aarch64*/bin/pw-cli | strings | grep -m1 'ld-linux\|ld-musl' || true)
echo "interp field: $INTERP"
ls "$R$INTERP" 2>/dev/null && echo "INTERP OK (exists in rootfs)" || echo "INTERP MISSING"
echo "== one DT_NEEDED lib (libpipewire) present =="
ls "$R"/nix/store/*pipewire*/lib/libpipewire-0.3.so* 2>/dev/null | head -2
