#!/bin/sh
# Prove the Nix-built guest daemons are real: install them into the dev
# rootfs, re-assemble the payload with the real kernel, and run the boot
# gates (input chain + pointer/focus chain) against QEMU.
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
export OX_BUSYBOX=/tmp/ox-aarch64/busybox
OX="/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
OUT=/nix/store/avvkj4lp4zrd51hdkilz827j9lqkl1nl-ox-guest-daemons-0.1.0

# 1. stage the Nix binaries where dev-pipeline.sh picks them up
mkdir -p /tmp/ox-rust
for b in oxcom oxpaymentsd ox-status inputd powerd; do
    cp -f "$OUT/bin/$b" /tmp/ox-rust/$b
done
echo "[nix-gates] Nix binaries staged into /tmp/ox-rust"

# 2. rebuild rootfs + payload (stub kernel) with the Nix artifacts.
# NOTE: dev-pipeline.sh needs bash (brace expansion), not sh.
bash "$OX/tools/dev-pipeline.sh" /tmp/ox-gfx 2>&1 | grep -E "guest daemon|PIPELINE|s6 runtime|ERROR"

# 3. swap stub kernel for the real one
bash "$OX/tools/build-payload.sh" qemu-virt-aarch64 \
    /tmp/ox-gfx/rootfs /tmp/ox-kbuild/Image /tmp/ox-gfx/payload 2>&1 | tail -2

# 4. boot gates
bash "$OX/tools/qemu-clean.sh" || true
echo "[nix-gates] === gfx-input-gate (Nix binaries) ==="
bash "$OX/tools/gfx-input-gate.sh" /tmp/ox-gfx/payload /tmp/ox-kbuild/Image
echo "[nix-gates] === gfx-pointer-gate (Nix binaries) ==="
bash "$OX/tools/gfx-pointer-gate.sh" /tmp/ox-gfx/payload /tmp/ox-kbuild/Image
echo "[nix-gates] ALL GATES GREEN WITH NIX-BUILT BINARIES"
