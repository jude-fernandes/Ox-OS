#!/bin/sh
K=/nix/store/kmyav51rzskjc17rwkyh1600djyv5yvs-linux-aarch64-unknown-linux-gnu-6.18.48
echo "=== Image present? ==="
ls -la "$K/Image" 2>/dev/null || { echo "no Image at that path"; ls "$K" | head -5; }
echo "=== zram strings ==="
strings "$K/Image" 2>/dev/null | grep -c "zram"
strings "$K/Image" 2>/dev/null | grep -m3 -i "zram"
echo "=== psi strings ==="
strings "$K/Image" 2>/dev/null | grep -m3 "pressure"
echo "=== lzo strings ==="
strings "$K/Image" 2>/dev/null | grep -m2 -i "lzo"
