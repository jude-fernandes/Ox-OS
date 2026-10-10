#!/bin/sh
set -eu
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
CFG=$("$NIX" build -L .#kernel-qemu.configfile --no-link --print-out-paths 2>/dev/null | tail -1)
echo "configfile: $CFG"
grep -E 'CONFIG_CRYPTO_AES_ARM64|CONFIG_CRYPTO_XTS=|CONFIG_CRYPTO_AES=|CONFIG_DM_CRYPT=' "$CFG"
