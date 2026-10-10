#!/bin/sh
# Build the full signed payload + kernel hermetically. Self-contained:
# safe to run in a recycled WSL VM. stdout: out paths; stderr: nix log.
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
"$NIX" build .#payload-qemu .#kernel-qemu --no-link --print-out-paths \
    --option cores 2 --max-jobs 1
