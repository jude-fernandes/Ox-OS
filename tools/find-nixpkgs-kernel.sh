#!/bin/sh
# Locate the nixpkgs kernel builder used by our flake and show its
# rustc/clang dependency gates.
set -eu
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
# The flake's nixpkgs source as realized in the store (flake input).
NS=$(nix flake metadata --json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for k,v in d['locks']['nodes'].items():
    if k=='nixpkgs' or 'nixos-24.11' in str(v.get('original',{}).get('ref','')):
        print(v['locked'].get('rev',''))
        break
")
echo "nixpkgs rev: $NS"
SRC=$(ls -d /nix/store/*-source 2>/dev/null | while read -r d; do
    if [ -f "$d/pkgs/os-specific/linux/kernel/generic.nix" ]; then echo "$d"; break; fi
done)
echo "kernel builder dir: $SRC"
grep -n "rustc\|clang\|bindgen" "$SRC/pkgs/os-specific/linux/kernel/generic.nix" | head -25
