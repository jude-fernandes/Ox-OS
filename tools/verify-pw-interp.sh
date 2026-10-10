#!/bin/sh
# Check the real ELF interpreter (PT_INTERP) of pw-cli and its presence
# in the rootfs, plus confirm every DT_NEEDED has a store dir in the rootfs.
set -eu
R=/nix/store/qlip7b41y6pawf267cfmg0x86fj80raf-ox-rootfs-qemu-0.1.0-phase1
PW=$(ls -d "$R"/nix/store/*pipewire-aarch64* | head -1)
READELF=$(command -v aarch64-unknown-linux-gnu-readelf || command -v readelf)
echo "== PT_INTERP =="
INTERP=$("$READELF" -l "$PW/bin/pw-cli" | grep -A1 'INTERP' | grep -o '/nix/store[^]]*' || true)
echo "interp: $INTERP"
if [ -n "$INTERP" ] && [ -e "$R$INTERP" ]; then
    echo "INTERP OK"
elif [ -n "$INTERP" ]; then
    echo "INTERP MISSING from rootfs"
fi
echo "== DT_NEEDED of pw-cli =="
LIBS=$("$READELF" -d "$PW/bin/pw-cli" | grep NEEDED | grep -o '\[.*\]' | tr -d '[]' || true)
for lib in $LIBS; do
    case "$lib" in
        */*) [ -e "$R$lib" ] && echo "OK  $lib" || echo "MISS $lib" ;;
        *)   echo "(unversioned) $lib" ;;
    esac
done
echo "== libc dir in closure =="
ls -d "$R"/nix/store/*musl*aarch64*/lib 2>/dev/null | head -2
