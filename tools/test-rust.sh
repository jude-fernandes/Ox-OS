#!/bin/sh
# Rust workspace gate: pinned-toolchain cargo test. Skips cleanly when no
# toolchain is installed so the suite stays runnable on bare hosts.
set -eu
cd "$(dirname "$0")/.."

CARGO=""
for c in "$(command -v cargo || true)" "$HOME/.cargo/bin/cargo"; do
    [ -n "$c" ] && [ -x "$c" ] && { CARGO="$c"; break; }
done
if [ -z "$CARGO" ]; then
    # rustup shims are per-user; a direct toolchain binary works for any caller
    for c in /home/*/.rustup/toolchains/*/bin/cargo /root/.rustup/toolchains/*/bin/cargo \
             /home/*/.cargo/bin/cargo; do
        [ -x "$c" ] && { CARGO="$c"; break; }
    done
fi
[ -n "$CARGO" ] || { echo "[ox-rust] SKIP: no cargo toolchain"; exit 0; }

export PATH="$(dirname "$CARGO"):$PATH"
cd rust
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/ox-rust-target}"
"$CARGO" test --workspace --locked --quiet
echo "[ox-rust] ALL GREEN"
