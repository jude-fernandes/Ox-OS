#!/bin/sh
EU=/nix/store/3fny8j8rynb0hqsqjh6xpyzir11ry82p-eudev-aarch64-unknown-linux-musl-3.2.14
echo "=== bin ==="; ls "$EU/bin" 2>/dev/null || echo none
echo "=== sbin ==="; ls "$EU/sbin" 2>/dev/null || echo none
echo "=== var/lib/udev/rules.d ==="; ls "$EU/var/lib/udev/rules.d" 2>/dev/null | head -30
echo "=== lib/udev ==="; ls "$EU/lib/udev" 2>/dev/null | head -10
echo "=== 78-sound-card SOUND_INITIALIZED ==="
grep -n "SOUND_INITIALIZED" "$EU/var/lib/udev/rules.d/78-sound-card.rules" 2>/dev/null || echo "rule file missing"
echo "=== needed ==="
readelf -d "$EU/sbin/udevd" 2>/dev/null | grep NEEDED
