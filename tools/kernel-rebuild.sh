#!/bin/sh
# Rebuild the kernel with VIRTIO_CONSOLE=y (background long job).
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
"$NIX" build .#kernel-qemu --no-link --print-out-paths \
    --option cores 2 --max-jobs 1 2>/tmp/kerr.txt > /tmp/kout.txt \
    || { echo "KERNEL BUILD FAILED"; tail -6 /tmp/kerr.txt; exit 1; }
cat /tmp/kout.txt
echo KERNEL_OK
# marker in the file itself (chain jobs watch kout.txt, not stdout)
echo KERNEL_OK >> /tmp/kout.txt
