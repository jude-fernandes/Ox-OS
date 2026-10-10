#!/bin/sh
# Ox play mode: boot the current payload in a window for HUMAN use —
# no gate assertions, no test taps, no timeout. The lockscreen, shell,
# app grid, package install, Settings, camera (vivid sensor) and wifi
# (hwsim + in-guest AP) are usable. Modem/NFC legs need the gate
# emulators (play-v2 wires those).
#
# Usage (from WSL):  sh /root/oxbuild/tools/play-ox.sh
# PIN: 1234 (dev default, rotatable on the pad).
# The window: OX_GFX=1 boots with the graphical framebuffer; connect
# a VNC viewer to localhost:5900 (or run under WSLg where the display
# appears natively).
set -eu
cd /root/oxbuild
P=$(readlink -f /root/oxbuild/gcroot-payload)
K=$(readlink -f /root/oxbuild/gcroot-kernel)/Image
[ -f "$P/payload.bin" ] || { echo "payload missing at $P"; exit 1; }
[ -f "$K" ] || { echo "kernel Image missing at $K"; exit 1; }
pkill -f '[q]emu-system-aarch64' 2>/dev/null || true
sleep 2
rm -rf /tmp/ox-play && mkdir -p /tmp/ox-play
cp -r "$P"/. /tmp/ox-play/
rm -f /tmp/ox-play/data.img /tmp/ox-play/data.img.key
echo "Ox play mode: booting... unlock PIN 1234. Ctrl-C here ends it."
OX_GFX=1 exec bash /root/oxbuild/targets/qemu-virt-aarch64/run-qemu.sh \
    /tmp/ox-play "$K" /tmp/ox-play/console.log
