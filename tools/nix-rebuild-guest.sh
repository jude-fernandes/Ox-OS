#!/bin/sh
# Rebuild guest-daemons via Nix after the rust-overlay pivot.
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"

# Windows-side edits can introduce CRLF; Nix and the embedded shell snippets
# are LF-sensitive.
sed -i 's/\r$//' flake.nix

# Build artifacts under ox/rust would be swept into cleanSource — the local
# flow always builds into CARGO_TARGET_DIR=/tmp, but clean up defensively.
if [ -d rust/target ]; then
    echo "removing stray rust/target build dir from the source tree"
    rm -rf rust/target
fi

echo "== nix flake lock (adds rust-overlay) =="
nix flake lock

echo "== nix flake check =="
nix flake check

echo "== nix build .#guest-daemons =="
nix build -L .#guest-daemons
echo "BUILD OK"
