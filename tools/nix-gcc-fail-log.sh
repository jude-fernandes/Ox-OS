#!/bin/sh
# Rebuild the failing musl gcc-wrapper drv with full -L logs to find the
# root failure.
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
nix build -L /nix/store/mwr8vsbn7s25ln8wzxkm7jjnhyx1ivvh-aarch64-unknown-linux-musl-gcc-wrapper-13.3.0.drv 2>&1 | head -80
