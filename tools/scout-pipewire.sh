#!/bin/sh
# Scout: does the cross-musl PipeWire evaluate, and how big is its
# dependency closure? (Feasibility check for the Phase-2 audio service.)
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
echo "== eval =="
nix eval --raw nixpkgs#pkgsCross.aarch64-multiplatform-musl.pipewire.version 2>/dev/null && echo
DRV=$(nix eval --raw nixpkgs#pkgsCross.aarch64-multiplatform-musl.pipewire.drvPath 2>/dev/null)
echo "drv: $DRV"
echo "== recursive derivation count =="
nix derivation show -r "$DRV" 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(len(d), 'derivations in closure')
names = sorted({v['env'].get('pname', v['env'].get('name','?')) for v in d.values()})
print('notable deps:', ', '.join(n for n in names if n in (
    'alsa-lib','dbus','glib','mesa','libdrm','systemd','libsndfile','ncurses',
    'readline','fftw','vulkan-loader','webrtc-audio-processing','lilv','lv2')) or '(none matched)')
"
