#!/usr/bin/env bash
# Host validation gate for the ox-init LUKS2 unlock path:
#   1. AES-256 FIPS vector + roundtrip, SHA-256, PBKDF2-HMAC-SHA256 vectors
#   2. end-to-end: unlock a real cryptsetup container; volume key must match
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
T=/tmp/ox-luks-test
rm -rf "$T"; mkdir -p "$T"

gcc -O0 -DOX_HOST_DEBUG -o "$T/luks-test" "$DIR/luks-test-host.c" || exit 1
"$T/luks-test" || exit 2

IMG="$T/data.img"
OX_DATA_MB=256 bash "$DIR/mkdata.sh" "$IMG" >/dev/null

VK_REF=$(cryptsetup luksDump --dump-volume-key --key-file "$IMG.key" "$IMG" |
         sed -n '/MK dump:/,$p' | tr -d ' \t\n' | grep -oE '[0-9a-f]{128}' | head -1)
VK_GOT=$("$T/luks-test" "$IMG" "$IMG.key" 2>/dev/null | awk '/VOLUMEKEY/ {print $2}')

if [ -z "$VK_REF" ] || [ -z "$VK_GOT" ]; then
    echo "LUKS E2E FAIL: could not obtain keys (ref='$VK_REF' got='$VK_GOT')"
    exit 3
fi
if [ "$VK_REF" != "$VK_GOT" ]; then
    echo "LUKS E2E FAIL: volume key mismatch"
    echo "  cryptsetup: $VK_REF"
    echo "  ox-init:    $VK_GOT"
    exit 4
fi
echo "LUKS2 unlock path ok (volume key matches cryptsetup)"
