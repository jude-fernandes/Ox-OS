#!/bin/sh
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
OUT=/nix/store/ff6wlvfazkc2fqhcjdjka3p8v4kr6zsf-pipewire-aarch64-unknown-linux-musl-1.2.7
"$NIX" path-info -rsh "$OUT" | awk '{s+=$2} END {printf "closure: %.1f MiB across %d paths\n", s/1048576, NR}'
"$NIX" path-info -rsh "$OUT" | sort -k2 -h | tail -6
