#!/bin/sh
WP=/nix/store/qbhp9byqvfcl6nckgvih6bpyp2pd7yw8-wireplumber-aarch64-unknown-linux-musl-0.5.8
echo "=== monitors/alsa.lua (head 80) ==="
sed -n '1,80p' "$WP/share/wireplumber/scripts/monitors/alsa.lua"
echo "=== alsa.lua device creation lines ==="
grep -n "SpaDevice\|LocalDevice\|enum" "$WP/share/wireplumber/scripts/monitors/alsa.lua" | head -20
