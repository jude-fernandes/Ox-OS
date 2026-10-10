#!/bin/sh
PW=$(ls -d /nix/store/*pipewire-aarch64-unknown-linux-musl-1.2.7/ 2>/dev/null | grep -v -- -dev | head -1)
WP=$(ls -d /nix/store/*wireplumber-aarch64-unknown-linux-musl-0.5.8/ 2>/dev/null | grep -v -- -dev | head -1)
echo "=== libspa-alsa DT_NEEDED ==="
readelf -d "$PW/lib/spa-0.2/alsa/libspa-alsa.so" | grep -E "NEEDED|RPATH|RUNPATH"
echo "=== wireplumber DT_NEEDED/RUNPATH ==="
readelf -d "$WP/bin/wireplumber" | grep -E "NEEDED|RPATH|RUNPATH"
echo "=== wpctl interp+needed ==="
readelf -d "$WP/bin/wpctl" | grep -E "NEEDED|RPATH|RUNPATH" | head
readelf -l "$WP/bin/wpctl" | grep -m1 INTERP || true
readelf -l "$WP/bin/wpctl" | grep -A1 INTERP | tail -1
echo "=== wireplumber interp ==="
readelf -l "$WP/bin/wireplumber" | grep -A1 INTERP | tail -1
echo "=== closure sizes ==="
echo "pipewire out: $(du -sh "$PW" | cut -f1)"
echo "wireplumber out: $(du -sh "$WP" | cut -f1)"
echo "=== libudev in nix store (linked from wp or spa)? ==="
ls -d /nix/store/*libudev* 2>/dev/null | head -3 || echo none
echo "=== pw bin listing ==="
ls "$PW/bin/"
