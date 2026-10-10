#!/bin/sh
# Rigorous PT_INTERP check: extract the string, require it start with
# /nix/store, then require it exists in the rootfs.
set -eu
R=/nix/store/qlip7b41y6pawf267cfmg0x86fj80raf-ox-rootfs-qemu-0.1.0-phase1
PW="$(ls -d "$R"/nix/store/*pipewire-aarch64* | head -1)"
INTERP="$(dd if="$PW/bin/pw-cli" bs=1 skip=512 count=107 2>/dev/null | tr -d '\0' | tr -d '\n')"
echo "interp bytes: '$INTERP'"
case "$INTERP" in
    /nix/store/*) echo "interp is a store path (good)" ;;
    *) echo "UNEXPECTED interp"; exit 1 ;;
esac
if [ -e "$R$INTERP" ]; then
    echo "INTERP OK — exists in rootfs"
else
    echo "INTERP MISSING"; exit 1
fi
