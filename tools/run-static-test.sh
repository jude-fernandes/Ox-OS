#!/bin/sh
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
sed -i 's/\r$//' tools/static-test.nix
nix build -L -f tools/static-test.nix 2>&1 | grep -aE "NIX_LDFLAGS|NIX_CFLAGS|plain gcc|collect2|ld:|== CC|t1|cannot find" | head -15
