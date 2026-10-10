#!/bin/sh
# Inspect the built wireplumber store path: layout, config components,
# dynamic-link facts, and whether the lean spa tree has a udev enumerator.
WP=/nix/store/qbhp9byqvfcl6nckgvih6bpyp2pd7yw8-wireplumber-aarch64-unknown-linux-musl-0.5.8
PW="$(ls -d /nix/store/*pipewire-aarch64* 2>/dev/null | head -1)"
echo "=== bin ==="
ls "$WP/bin"
echo "=== lib top ==="
ls "$WP/lib" | head
echo "=== lib/wireplumber-0.5 ==="
ls "$WP/lib/wireplumber-0.5" 2>/dev/null | head -30
echo "=== share/wireplumber ==="
ls "$WP/share/wireplumber" 2>/dev/null
echo "=== wireplumber.conf components section ==="
sed -n '/wireplumber.components/,/^]/p' "$WP/share/wireplumber/wireplumber.conf" 2>/dev/null | head -60
echo "=== monitor.alsa section present? ==="
grep -n "monitor.alsa" "$WP/share/wireplumber/wireplumber.conf" | head
echo "=== spa alsa dir (lean pw) ==="
ls "$PW/lib/spa-0.2/alsa" 2>/dev/null
echo "=== udev enum inside libspa-alsa? ==="
grep -c "api.alsa.enum.udev" "$PW/lib/spa-0.2/alsa/libspa-alsa.so" 2>/dev/null || echo "no libspa-alsa.so"
echo "=== libudev refs in wireplumber bins ==="
grep -l "libudev" "$WP/bin/"* 2>/dev/null || echo "none"
echo "=== interp + runpath of wireplumber ==="
strings "$WP/bin/wireplumber" 2>/dev/null | grep -m1 "ld-musl"
readelf -d "$WP/bin/wireplumber" 2>/dev/null | grep -E "NEEDED|RPATH|RUNPATH" | head -12
echo "=== closure size (paths in wireplumber closure) ==="
CLOS="$(nix build --print-out-paths --no-link "$(dirname "$WP")" 2>/dev/null | head -1)"
echo "clos=$CLOS"
