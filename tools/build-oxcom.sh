#!/bin/sh
# Cross-build the guest Rust daemons (oxcom + oxpaymentsd) as static aarch64
# binaries via the pinned toolchain + musl target. Output goes to
# /tmp/ox-rust/ (picked up by dev-pipeline.sh; override with OXCOM_OUT).
# Skips cleanly (exit 0, "SKIP" marker) when no toolchain — same contract as
# tools/test-rust.sh so the suite stays runnable on bare hosts.
set -eu
cd "$(dirname "$0")/.."

CARGO=""
for c in "$(command -v cargo || true)" "$HOME/.cargo/bin/cargo"; do
    [ -n "$c" ] && [ -x "$c" ] && { CARGO="$c"; break; }
done
if [ -z "$CARGO" ]; then
    for c in /home/*/.rustup/toolchains/*/bin/cargo /root/.rustup/toolchains/*/bin/cargo \
             /home/*/.cargo/bin/cargo; do
        [ -x "$c" ] && { CARGO="$c"; break; }
    done
fi
[ -n "$CARGO" ] || { echo "SKIP: no cargo toolchain"; exit 0; }
export PATH="$(dirname "$CARGO"):$PATH"

TARGET=aarch64-unknown-linux-musl
# Filesystem check (not `rustup target list`): the suite may run as a user
# whose PATH has only the direct toolchain binaries, no rustup shim.
SYSROOT="$("$(dirname "$CARGO")/rustc" --print sysroot)"
if [ ! -d "$SYSROOT/lib/rustlib/$TARGET" ]; then
    RUSTUP="$(command -v rustup || true)"
    [ -n "$RUSTUP" ] || RUSTUP="$(dirname "$CARGO")/rustup"
    if [ -x "$RUSTUP" ]; then
        echo "[ox-cross] installing rust target $TARGET"
        "$RUSTUP" target add "$TARGET"
    else
        echo "ERROR: $TARGET not installed and no rustup to fetch it" >&2
        exit 3
    fi
fi

cd rust
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/ox-rust-target}"

# The musl target's default linker is the HOST cc, which cannot link aarch64
# CRT objects. Use the toolchain's own cross-linker, scoped to the target so
# host proc-macros/build scripts keep their normal toolchain.
RUSTLLD="$SYSROOT/lib/rustlib/x86_64-unknown-linux-gnu/bin/rust-lld"
[ -x "$RUSTLLD" ] || { echo "ERROR: rust-lld not found at $RUSTLLD" >&2; exit 3; }
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="$RUSTLLD"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="-C linker-flavor=ld.lld"

"$CARGO" build --release --locked --target "$TARGET" -p oxcom --features gui --quiet
"$CARGO" build --release --locked --target "$TARGET" -p oxpaymentsd -p ox-status -p inputd -p powerd --quiet

OUT="${OXCOM_OUT:-/tmp/ox-rust}"
mkdir -p "$OUT"
for bin in oxcom oxpaymentsd ox-status inputd powerd; do
    SRC="$CARGO_TARGET_DIR/$TARGET/release/$bin"
    [ -f "$SRC" ] || { echo "ERROR: $SRC missing after build" >&2; exit 4; }
    if command -v file >/dev/null 2>&1; then
        file "$SRC" | grep -qi aarch64 || {
            echo "ERROR: $SRC is not aarch64" >&2; exit 4; }
        file "$SRC" | grep -qi "statically linked" || {
            echo "ERROR: $SRC is not static (guest has no shared libc)" >&2; exit 4; }
    fi
    cp -f "$SRC" "$OUT/$bin"
    echo "[ox-cross] $bin -> $OUT/$bin ($(wc -c <"$SRC") bytes, aarch64 musl static)"
done
echo "[ox-cross] ALL GREEN"
