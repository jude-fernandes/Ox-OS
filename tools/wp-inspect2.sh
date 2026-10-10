#!/bin/sh
WP=/nix/store/qbhp9byqvfcl6nckgvih6bpyp2pd7yw8-wireplumber-aarch64-unknown-linux-musl-0.5.8
PW="$(ls -d /nix/store/*pipewire-aarch64* 2>/dev/null | head -1)"
echo "=== component blocks 340-400 ==="
sed -n '340,400p' "$WP/share/wireplumber/wireplumber.conf"
echo "=== component blocks 670-700 ==="
sed -n '670,700p' "$WP/share/wireplumber/wireplumber.conf"
echo "=== scripts dir ==="
ls "$WP/share/wireplumber/scripts" | head -30
echo "=== lean pw spa-0.2 tree ==="
ls "$PW/lib/spa-0.2/"
echo "=== alsa plugin search ==="
find "$PW/lib/spa-0.2" -name "*alsa*" 2>/dev/null
echo "=== udev string anywhere in spa tree ==="
grep -rl "api.alsa.enum.udev" "$PW/lib/spa-0.2" 2>/dev/null || echo NONE
echo "=== api.alsa.pcm.sink location ==="
grep -rl "api.alsa.pcm.sink" "$PW/lib/spa-0.2" 2>/dev/null || echo NONE
