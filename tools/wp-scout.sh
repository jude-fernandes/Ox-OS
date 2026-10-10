#!/bin/sh
# Scout wireplumber in the pinned nixpkgs rev: version, derivation source,
# and which pipewire/lua it binds to. Read-only, no builds.
set -e
. /root/.nix-profile/etc/profile.d/nix.sh 2>/dev/null || . /etc/profile.d/nix.sh
REV=50ab793786d9de88ee30ec4e4c24fb4236fc2674
echo "=== version ==="
nix eval --raw "github:NixOS/nixpkgs/$REV#wireplumber.version"; echo
echo "=== derivation source position ==="
POS=$(nix eval --raw "github:NixOS/nixpkgs/$REV#wireplumber.meta.position" 2>/dev/null || true)
echo "POS=$POS"
FILE=${POS%:*}
echo "=== derivation file: $FILE ==="
cat "$FILE"
