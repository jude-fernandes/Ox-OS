#!/bin/sh
# Boot-image packager gate: build v0/v1/v2/v3/v4 images from fixture blobs,
# verify each with the tool's own parser, and require byte-identical
# deterministic rebuilds. Exits non-zero on any failure.
set -eu
cd "$(dirname "$0")/.."
TOOL=tools/ox-mkbootimg.py
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

say() { printf '[ox-bootimg] %s\n' "$*"; }
fail() { printf '[ox-bootimg] FAIL: %s\n' "$*" >&2; exit 1; }

python3 - <<EOF
import os, random
random.seed(20260826)
open("$TMP/kernel", "wb").write(b"OxKernelImage\x00" + bytes(random.getrandbits(8) for _ in range(5000)))
open("$TMP/ramdisk", "wb").write(b"OxInitramfsCpioGzip\x00" + bytes(random.getrandbits(8) for _ in range(900)))
open("$TMP/dtb", "wb").write(bytes(random.getrandbits(8) for _ in range(1234)))
open("$TMP/second", "wb").write(b"\x01" * 100)
EOF

COMMON="--kernel $TMP/kernel --ramdisk $TMP/ramdisk --board oxos --cmdline 'console=ttyMSM0,115200n8 printk.devkmsg=on' --os-version 15 --os-patch-level 2026-08"

for hv in 0 1; do
    eval "python3 $TOOL $COMMON --header-version $hv -o '$TMP/b$hv.img'"
done
eval "python3 $TOOL $COMMON --second '$TMP/second' --header-version 2 \
    --dtb '$TMP/dtb' --pagesize 2048 -o '$TMP/b2.img'"
eval "python3 $TOOL $COMMON --header-version 3 --vendor-boot '$TMP/vb3.img' \
    -o '$TMP/b3.img'"
eval "python3 $TOOL $COMMON --header-version 4 --dtb '$TMP/dtb' \
    --vendor-ramdisk '$TMP/second' --vendor-cmdline 'androidboot.vbmeta=skip' \
    --vendor-boot '$TMP/vb4.img' -o '$TMP/b4.img'"

for f in b0 b1 b2 b3 b4 vb3 vb4; do
    python3 $TOOL --output "$TMP/$f.img" --verify >/dev/null \
        || fail "verify $f"
    say "verify ok   $f.img"
done

# determinism: rebuild v2 and v4 bit-identical
for pair in "2:$TMP/b2.img" "4:$TMP/b4.img"; do
    hv=${pair%%:*}; ref=${pair#*:}
    case $hv in
      2) EXTRA="--second $TMP/second --dtb $TMP/dtb --pagesize 2048";;
      4) EXTRA="--dtb $TMP/dtb";;
    esac
    eval "python3 $TOOL $COMMON --header-version $hv $EXTRA -o '$TMP/rebuild.img'"
    cmp -s "$ref" "$TMP/rebuild.img" || fail "non-deterministic rebuild v$hv"
    say "determinism ok v$hv"
done

# tamper detection: flip one kernel byte -> SHA1 must fail verification
cp "$TMP/b2.img" "$TMP/tampered.img"
python3 - <<EOF
p="$TMP/tampered.img"
d=bytearray(open(p,"rb").read())
d[4096+100]^=0xFF
open(p,"wb").write(d)
EOF
if python3 $TOOL --output "$TMP/tampered.img" --verify >/dev/null 2>&1; then
    fail "tampered image passed verification"
fi
say "tamper rejection ok"

say "ALL GREEN"
