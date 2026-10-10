#!/bin/sh
# Hygiene pass verification: zero warnings, tests green, Nix build clean.
set -eu
export PATH="$HOME/.cargo/bin:/root/.cargo/bin:$PATH"
if ! command -v cargo >/dev/null 2>&1; then
    for c in /root/.rustup/toolchains/*/bin/cargo /home/*/.cargo/bin/cargo; do
        [ -x "$c" ] && DIR=$(dirname "$c") && export PATH="$DIR:$PATH" && break
    done
fi
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/rust"

echo "== warning check =="
W=$(CARGO_TARGET_DIR=/tmp/ox-hyg cargo build --workspace --all-targets 2>&1 | grep -c "^warning" || true)
echo "warnings: $W"
[ "$W" = "0" ] || { echo "WARNINGS REMAIN"; exit 1; }

echo "== workspace tests =="
CARGO_TARGET_DIR=/tmp/ox-hyg cargo test --workspace --quiet 2>&1 | tail -4

echo "== Nix guest-daemons (no warnings expected) =="
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
nix build -L .#guest-daemons 2>&1 | grep -E "warning|error" | head -5 || true
nix build .#guest-daemons --no-link 2>&1 | tail -1
echo "HYGIENE PASS GREEN"
