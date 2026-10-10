#!/bin/sh
# Cross-build a static busybox for the guest architecture.
# usage: build-busybox.sh [OUT_DIR] [ARCH_PREFIX]
set -eu
OUT="${1:-/tmp/ox-aarch64}"
PREFIX="${2:-aarch64-linux-gnu-}"
VER="1.36.1"
SRC="$OUT/src"

mkdir -p "$OUT"
TARBALL="$OUT/busybox-$VER.tar.bz2"
if [ ! -f "$TARBALL" ]; then
    python3 - "$VER" "$TARBALL" <<'EOF'
import shutil, sys, urllib.request
ver, dest = sys.argv[1], sys.argv[2]
url = f"https://busybox.net/downloads/busybox-{ver}.tar.bz2"
print("downloading", url, flush=True)
with urllib.request.urlopen(url, timeout=300) as r, open(dest, "wb") as f:
    shutil.copyfileobj(r, f)
EOF
fi

SUMFILE="$OUT/busybox.sha256"
URL_SHA=$(python3 - "$VER" <<'EOF'
import sys, urllib.request
ver = sys.argv[1]
with urllib.request.urlopen(
        f"https://busybox.net/downloads/busybox-{ver}.tar.bz2.sha256",
        timeout=60) as r:
    print(r.read().decode().split()[0])
EOF
)
echo "$URL_SHA  $TARBALL" | sha256sum -c -
echo "$URL_SHA" > "$SUMFILE"

if [ ! -d "$SRC" ]; then
    mkdir -p "$SRC"
    tar -xjf "$TARBALL" -C "$SRC" --strip-components=1
fi

cd "$SRC"
make ARCH=arm64 CROSS_COMPILE="$PREFIX" defconfig >/dev/null
sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
yes "" | make ARCH=arm64 CROSS_COMPILE="$PREFIX" oldconfig >/dev/null 2>&1 || true
make ARCH=arm64 CROSS_COMPILE="$PREFIX" -j"$(nproc)" >"$OUT/build.log" 2>&1

cp busybox "$OUT/busybox"
file "$OUT/busybox"
SIZE=$(wc -c <"$OUT/busybox")
echo "OXMILESTONE name=busybox-built size=$SIZE arch=arm64-static"
