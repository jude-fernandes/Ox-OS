#!/bin/sh
# Build wireplumber-lean from the flake; log to /tmp/wpbuild.log.
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
"$NIX" build .#wireplumber-lean --no-link --print-out-paths \
    --option cores 2 --max-jobs 1 2>/tmp/wperr.txt > /tmp/wpout.txt \
    || { echo "BUILD FAILED"; tail -6 /tmp/wperr.txt; exit 1; }
cat /tmp/wpout.txt
echo BUILD_OK
