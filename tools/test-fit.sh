#!/bin/sh
# FIT builder gate: build .itb, confirm components via dumpimage, require
# byte-identical deterministic rebuild. Needs u-boot-tools (mkimage).
set -eu
cd "$(dirname "$0")/.."
command -v mkimage >/dev/null || { echo "SKIP: no mkimage"; exit 0; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

say() { printf '[ox-fit] %s\n' "$*"; }
fail() { printf '[ox-fit] FAIL: %s\n' "$*" >&2; exit 1; }

python3 - <<EOF
import random
random.seed(20260826)
open("$TMP/Image", "wb").write(b"OxKernel\x00" + bytes(random.getrandbits(8) for _ in range(4000)))
open("$TMP/initrd.gz", "wb").write(b"OxInitramfs\x00" + bytes(random.getrandbits(8) for _ in range(800)))
open("$TMP/rk3399.dtb", "wb").write(bytes(random.getrandbits(8) for _ in range(600)))
open("$TMP/soc2.dtb", "wb").write(bytes(random.getrandbits(8) for _ in range(700)))
EOF

python3 tools/ox-mkfit.py --kernel "$TMP/Image" --ramdisk "$TMP/initrd.gz" \
    --dtb "$TMP/rk3399.dtb" --dtb "$TMP/soc2.dtb" \
    --description "oxos test" --load-addr 0x08080000 -o "$TMP/ox.itb" >/dev/null

dumpimage -l "$TMP/ox.itb" | grep -q "kernel-1" || fail "kernel node missing"
dumpimage -l "$TMP/ox.itb" | grep -q "ramdisk-1" || fail "ramdisk node missing"
dumpimage -l "$TMP/ox.itb" | grep -q "fdt-2" || fail "second dtb missing"
say "components ok (kernel/ramdisk/2x dtb)"

# rebuild after a deliberate delay: two builds in the same wall-clock second
# can match by luck if the builder embeds a timestamp (mkimage's FIT stamp
# was caught exactly this way)
sleep 1.5
python3 tools/ox-mkfit.py --kernel "$TMP/Image" --ramdisk "$TMP/initrd.gz" \
    --dtb "$TMP/rk3399.dtb" --dtb "$TMP/soc2.dtb" \
    --description "oxos test" --load-addr 0x08080000 -o "$TMP/rebuild.itb" >/dev/null
cmp -s "$TMP/ox.itb" "$TMP/rebuild.itb" || fail "non-deterministic FIT"
say "determinism ok"

say "ALL GREEN"
