#!/bin/sh
PW=$(ls -d /nix/store/*pipewire-aarch64-unknown-linux-musl-1.2.7/ 2>/dev/null | grep -v -- -dev | head -1)
echo "PW=$PW"
echo "=== spa-0.2 tree ==="
ls "$PW/lib/spa-0.2/"
echo "=== alsa plugin ==="
find "$PW/lib/spa-0.2" -name "*alsa*"
echo "=== udev enum ==="
grep -rl "api.alsa.enum.udev" "$PW/lib/spa-0.2" 2>/dev/null || echo NONE
echo "=== pcm.sink ==="
grep -rl "api.alsa.pcm.sink" "$PW/lib/spa-0.2" 2>/dev/null || echo NONE
echo "=== spa lib dir (plugin libspa-alsa) ==="
ls "$PW/lib/spa-0.2/alsa/" 2>/dev/null || true
