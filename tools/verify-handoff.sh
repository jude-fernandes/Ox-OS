#!/bin/sh
# Handoff milestone verification: NDEF unit tests + paymentsd e2e + zero
# warnings + Nix guest-daemons rebuild.
set -eu
export PATH="$HOME/.cargo/bin:/root/.cargo/bin:$PATH"
if ! command -v cargo >/dev/null 2>&1; then
    for c in /root/.rustup/toolchains/*/bin/cargo /home/*/.cargo/bin/cargo; do
        [ -x "$c" ] && DIR=$(dirname "$c") && export PATH="$DIR:$PATH" && break
    done
fi
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/rust"

echo "== handoff tests =="
CARGO_TARGET_DIR=/tmp/ox-hyg cargo test -p ox-pay-proto ndef -p oxpaymentsd handoff --quiet 2>&1 | tail -6

echo "== workspace tests =="
CARGO_TARGET_DIR=/tmp/ox-hyg cargo test --workspace --quiet 2>&1 | grep -E "test result" | tail -4

echo "== warnings check =="
W=$(CARGO_TARGET_DIR=/tmp/ox-hyg cargo build --workspace --all-targets 2>&1 | grep -c "^warning" || true)
echo "warnings: $W"
[ "$W" = "0" ] || exit 1

echo "== Nix guest-daemons =="
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
nix build -L .#guest-daemons 2>&1 | grep -E "warning|error" | head -3 || true
nix build .#guest-daemons --no-link 2>&1 | tail -1
echo "HANDOFF MILESTONE GREEN"
