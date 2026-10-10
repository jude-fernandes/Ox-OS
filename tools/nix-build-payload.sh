#!/bin/sh
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
sed -i 's/\r$//' targets/qemu-virt-aarch64/payload.nix
nix build -L .#payload-qemu 2>&1 | tail -15
P=$(nix eval --raw .#payload-qemu)
echo "payload: $P"
ls -la "$P"
echo "== kernel Image present =="
ls -la "$P/Image" || ls -la "$(readlink result)/Image" 2>/dev/null || true
echo "== payload determinism probe: rebuild =="
nix build -L .#payload-qemu 2>&1 | tail -2
P2=$(nix eval --raw .#payload-qemu)
[ "$P" = "$P2" ] && echo "DETERMINISTIC: same store path" || echo "PATH CHANGED: $P -> $P2"
echo "PAYLOAD OK"
