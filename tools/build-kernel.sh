#!/bin/sh
# Cross-build the Ox OS kernel for a target from pinned mainline LTS.
# usage: build-kernel.sh [OUT_DIR]
# Version + sha256 are taken from kernel.org releases.json (longterm) and the
# downloaded tarball is verified against it before extraction (supply-chain gate).
set -eu

OUT="${1:-/tmp/ox-kbuild}"
SRC="$OUT/src"
mkdir -p "$OUT"
TOOLSDIR="$(cd "$(dirname "$0")" && pwd)"
FRAGS="$(cd "$TOOLSDIR/../kernel/fragments" && pwd)"

META=$(python3 - <<'EOF'
import json, urllib.request
with urllib.request.urlopen("https://www.kernel.org/releases.json", timeout=60) as r:
    data = json.load(r)
for rel in data["releases"]:
    if rel.get("moniker") == "longterm":
        print(rel["version"], rel["source"])
        break
EOF
)
VER=$(printf '%s' "$META" | cut -d' ' -f1)
SRC_URL=$(printf '%s' "$META" | cut -d' ' -f2)
[ -n "$VER" ] && [ -n "$SRC_URL" ] || { echo "ERROR: could not resolve longterm version" >&2; exit 2; }

SUMS_LINE=$(python3 - "$VER" <<'EOF'
import sys, urllib.request
ver = sys.argv[1]
with urllib.request.urlopen(
        "https://cdn.kernel.org/pub/linux/kernel/v6.x/sha256sums.asc",
        timeout=60) as r:
    for line in r.read().decode().splitlines():
        if line.strip().endswith(f"linux-{ver}.tar.xz"):
            print(line.split()[0])
            break
EOF
)
SHA="$SUMS_LINE"
[ -n "$SHA" ] || { echo "ERROR: no sha256 for linux-$VER" >&2; exit 2; }
echo "kernel: linux-$VER (longterm) sha256=$SHA"

TARBALL="$OUT/linux-$VER.tar.xz"
if [ ! -f "$TARBALL" ]; then
    python3 - "$SRC_URL" "$TARBALL" <<'EOF'
import shutil, sys, urllib.request
url, dest = sys.argv[1], sys.argv[2]
print("downloading", url, flush=True)
with urllib.request.urlopen(url, timeout=600) as r, open(dest, "wb") as f:
    shutil.copyfileobj(r, f)
EOF
fi

echo "$SHA  $TARBALL" | sha256sum -c -

if [ ! -d "$SRC" ]; then
    mkdir -p "$SRC"
    tar -xJf "$TARBALL" -C "$SRC" --strip-components=1
fi

cd "$SRC"
cp "$FRAGS/base-mobile.config" "$FRAGS/qemu-virt-aarch64.config" "$OUT/"
scripts/kconfig/merge_config.sh -m arch/arm64/configs/defconfig \
    "$OUT/base-mobile.config" "$OUT/qemu-virt-aarch64.config" >"$OUT/merge.log" 2>&1
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig >>"$OUT/merge.log" 2>&1

JOBS=$(nproc)
echo "building with $JOBS jobs..."
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$JOBS" Image >"$OUT/build.log" 2>&1

cp arch/arm64/boot/Image "$OUT/Image"
cp .config "$OUT/kernel.config"

{
    echo "OX_KERNEL_VER=$VER"
    echo "OX_KERNEL_SHA256=$SHA"
} >"$OUT/pin.env"

OXM_TMS="$(cut -d' ' -f1 /proc/uptime 2>/dev/null || echo 0)"
SIZE=$(wc -c <"$OUT/Image")
echo "OXMILESTONE name=kernel-built tms=$OXM_TMS ver=$VER size=$SIZE"
