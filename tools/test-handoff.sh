#!/bin/sh
set -eu
export PATH="$HOME/.cargo/bin:/root/.cargo/bin:$PATH"
if ! command -v cargo >/dev/null 2>&1; then
    for c in /root/.rustup/toolchains/*/bin/cargo /home/*/.cargo/bin/cargo; do
        [ -x "$c" ] && DIR=$(dirname "$c") && export PATH="$DIR:$PATH" && break
    done
fi
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/rust"
CARGO_TARGET_DIR=/tmp/ox-hyg cargo test --workspace handoff 2>&1 \
    | grep -E "running [0-9]+|::handoff|test result" | head -20
