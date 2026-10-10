#!/bin/sh
# Run host tests for the receipts milestone (rustup lives under /root).
cd "$(dirname "$0")/../rust" || exit 1
export PATH="/root/.cargo/bin:/root/.rustup/toolchains/1.82.0-x86_64-unknown-linux-gnu/bin:$PATH"
command -v cargo >/dev/null 2>&1 || { echo "no cargo"; ls /root/.rustup/toolchains 2>/dev/null; exit 9; }
exec cargo test -p oxpaymentsd -p oxctl "$@"
