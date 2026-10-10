#!/bin/sh
WP=/nix/store/qbhp9byqvfcl6nckgvih6bpyp2pd7yw8-wireplumber-aarch64-unknown-linux-musl-0.5.8
CONF="$WP/share/wireplumber/wireplumber.conf"
echo "=== profiles ==="
grep -n -A40 "wireplumber.profiles" "$CONF" | head -70
echo "=== features ==="
grep -n -A25 "wireplumber.features" "$CONF" | head -35
echo "=== alsa monitor args (monitor.alsa section) ==="
grep -n -B2 -A20 "monitor.alsa.properties" "$CONF" | head -40
