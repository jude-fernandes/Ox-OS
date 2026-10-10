#!/bin/sh
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
"$NIX" build .#guest-daemons --no-link --option cores 2 --max-jobs 1 2>&1 | tail -25
