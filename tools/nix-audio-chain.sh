#!/bin/sh
# Full audio-milestone chain: eval check -> rebuild kernel (SND options) ->
# rootfs (snd-test player) -> payload -> run the audio gate.
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
for f in flake.nix kernel/kernel.nix system/rootfs.nix system/snd-test.nix \
         targets/qemu-virt-aarch64/payload.nix tools/audio-gate.sh \
         system/s6-rc-source/audio-selftest/up; do
    sed -i 's/\r$//' "$f"
done

echo "== flake check =="
nix flake check 2>&1 | tail -2

echo "== build kernel (SND options) =="
nix build -L .#kernel-qemu 2>&1 | tail -3
K=$(readlink result); echo "kernel: $K"

echo "== build rootfs =="
nix build -L .#rootfs-qemu 2>&1 | tail -3
R=$(readlink result)
ls "$R/usr/bin/ox-snd-test" && file "$R/usr/bin/ox-snd-test" | head -1

echo "== build payload =="
nix build -L .#payload-qemu 2>&1 | tail -2
P=$(readlink result); echo "payload: $P"

echo "== audio gate =="
rm -rf /tmp/ox-audio-gate && mkdir -p /tmp/ox-audio-gate
cp -r "$P"/. /tmp/ox-audio-gate/
bash "$PWD/tools/audio-gate.sh" /tmp/ox-audio-gate "$K/Image"
echo "AUDIO MILESTONE COMPLETE"
