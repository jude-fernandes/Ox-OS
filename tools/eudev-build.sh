#!/bin/sh
# Build guest eudev from the flake; log to /tmp/eudevbuild.log.
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
"$NIX" build .#eudev --no-link --print-out-paths \
    --option cores 2 --max-jobs 1 2>/tmp/eudevbuild.log > /tmp/eudevout.txt \
    || { echo "BUILD FAILED"; tail -8 /tmp/eudevbuild.log; exit 1; }
cat /tmp/eudevout.txt
echo BUILD_OK
