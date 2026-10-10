#!/bin/sh
set -e
. /root/.nix-profile/etc/profile.d/nix.sh 2>/dev/null || . /etc/profile.d/nix.sh
PW=$(ls -d /nix/store/*pipewire-aarch64-unknown-linux-musl-1.2.7/ 2>/dev/null | grep -v -- -dev | head -1)
echo "=== pipewire udev rules shipped? ==="
find "$PW" -name "*.rules" 2>/dev/null
echo "=== eudev eval (cross musl) ==="
nix eval --raw "github:NixOS/nixpkgs/50ab793786d9de88ee30ec4e4c24fb4236fc2674#pkgsCross.aarch64-multiplatform-musl.eudev.version" 2>&1; echo
echo "=== eudev derivation position ==="
POS=$(nix eval --raw "github:NixOS/nixpkgs/50ab793786d9de88ee30ec4e4c24fb4236fc2674#pkgsCross.aarch64-multiplatform-musl.eudev.meta.position" 2>/dev/null || true)
echo "POS=$POS"
FILE=${POS%:*}
sed -n '1,60p' "$FILE"
