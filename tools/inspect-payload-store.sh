#!/bin/sh
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
echo "== paths file =="
cat /tmp/ox-nix-paths
echo "== all payload outputs in store =="
ls -d /nix/store/*ox-payload-qemu* 2>/dev/null || echo "(none)"
echo "== rebuild verbose =="
nix build -L .#payload-qemu --no-link --print-out-paths 2>&1 | tail -5
P=$(nix eval --raw .#payload-qemu 2>/dev/null || true)
echo "eval path: $P"
ls "$P" 2>&1 | head -5
