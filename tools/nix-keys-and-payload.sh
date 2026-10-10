#!/bin/sh
# Re-pin the dev-release key (it disappeared from the repo once) and build
# the payload in the same breath, verifying the key right before the build.
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
OX="/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"

mkdir -p "$OX/keys"
# Copy only when missing: re-copying bumps the mtime and changes the flake
# source hash, which would invalidate the payload derivation every run.
[ -f "$OX/keys/dev-release.pem" ] || \
    cp -p /tmp/ox-gfx/keys/dev-release.pem "$OX/keys/dev-release.pem"
[ -f "$OX/keys/dev-release.pub" ] || \
    cp -p /tmp/ox-gfx/keys/dev-release.pub "$OX/keys/dev-release.pub" 2>/dev/null || true
ls -la "$OX/keys"
[ -f "$OX/keys/dev-release.pem" ] || { echo "KEY MISSING AGAIN"; exit 9; }

cd "$OX"
sed -i 's/\r$//' targets/qemu-virt-aarch64/payload.nix
nix build -L .#payload-qemu 2>&1 | tail -12
P=$(nix eval --raw .#payload-qemu)
echo "payload: $P"
ls -la "$P"
echo "== second build (determinism) =="
nix build -L .#payload-qemu 2>&1 | tail -1
P2=$(nix eval --raw .#payload-qemu)
[ "$P" = "$P2" ] && echo "DETERMINISTIC: same store path" || echo "PATH CHANGED: $P -> $P2"
echo "== keys still present after build? =="
ls -la "$OX/keys"
echo "PAYLOAD OK"
