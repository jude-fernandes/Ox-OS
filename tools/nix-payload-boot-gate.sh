#!/bin/sh
# Boot-gate the fully Nix-built payload: copy the store payload to writable
# scratch (run-qemu creates data.img), then run the gfx input gate with the
# Nix-built kernel + Nix-built rootfs.
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
OX="/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
cd "$OX"
# Build (not just eval) so the store paths exist, then take them in order.
nix build -L .#payload-qemu .#kernel-qemu --no-link --print-out-paths > /tmp/ox-nix-paths
PAYSTORE=$(sed -n 1p /tmp/ox-nix-paths)
KERNEL=$(sed -n 2p /tmp/ox-nix-paths)
echo "[nix-boot] payload: $PAYSTORE"
echo "[nix-boot] kernel:  $KERNEL"
file "$KERNEL/Image"

rm -rf /tmp/ox-nix-gate
mkdir -p /tmp/ox-nix-gate
cp -r "$PAYSTORE"/. /tmp/ox-nix-gate/

bash "$OX/tools/qemu-clean.sh" || true
echo "[nix-boot] === gfx-input-gate (Nix kernel + Nix rootfs) ==="
bash "$OX/tools/gfx-input-gate.sh" /tmp/ox-nix-gate "$KERNEL/Image"
echo "[nix-boot] NIX PAYLOAD BOOT GATE GREEN"
