#!/bin/sh
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
"$NIX" build .#guest-daemons --no-link --print-out-paths --option cores 2 --max-jobs 1
echo "RC=$?"
ls "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox" >/dev/null # sanity
