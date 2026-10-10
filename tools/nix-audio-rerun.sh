#!/bin/sh
# Re-run the audio milestone after the console-routing fix: rebuild payload
# (rootfs recompiles the s6 DB with the /dev/console redirect), then gate.
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
sed -i 's/\r$//' system/s6-rc-source/audio-selftest/run \
    system/s6-rc-source/audio-selftest/type \
    targets/qemu-virt-aarch64/payload.nix

echo "== rebuild payload (rootfs DB + verbose cmdline) =="
nix build -L .#payload-qemu .#kernel-qemu --no-link --print-out-paths > /tmp/ox-nix-paths
P=$(sed -n 1p /tmp/ox-nix-paths)
K=$(sed -n 2p /tmp/ox-nix-paths)
echo "payload: $P"
echo "== audio-selftest in compiled DB (servicedirs layout)? =="
R=$(nix eval --raw .#rootfs-qemu)
ls "$R/etc/s6-rc/compiled/servicedirs/" 2>/dev/null | grep -i audio \
    || echo "(not in servicedirs — only longruns appear there; check gate output)"

echo "== audio gate =="
rm -rf /tmp/ox-audio-gate && mkdir -p /tmp/ox-audio-gate
cp -r "$P"/. /tmp/ox-audio-gate/
bash tools/audio-gate.sh /tmp/ox-audio-gate "$K/Image"
echo "AUDIO MILESTONE COMPLETE"
