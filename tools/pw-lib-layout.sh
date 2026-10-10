#!/bin/sh
set -eu
P=/nix/store/ff6wlvfazkc2fqhcjdjka3p8v4kr6zsf-pipewire-aarch64-unknown-linux-musl-1.2.7
echo "== lib/ =="
ls "$P/lib/" | head -8
echo "== lib/pipewire-0.3 (modules) =="
ls "$P/lib/pipewire-0.3/" 2>/dev/null | head -6
echo "== lib/spa-0.2 =="
ls "$P/lib/spa-0.2/" 2>/dev/null | head -6
echo "== protocol-native module present? =="
ls "$P/lib/pipewire-0.3/libpipewire-module-protocol-native.so" 2>/dev/null || echo MISSING
