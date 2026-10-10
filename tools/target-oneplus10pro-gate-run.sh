#!/bin/sh
# Build the OnePlus 10 Pro (SM8450) image set and run the generic
# Android-chain gate. No --offline: first run fetches what it lacks;
# gc-roots on success.
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd /root/oxbuild
"$NIX" build .#image-oneplus10pro --no-link --print-out-paths \
    --option cores 4 --max-jobs 1 \
    2>/tmp/nixerr.txt > /tmp/nixout.txt || { echo "BUILD FAILED"; tail -8 /tmp/nixerr.txt; exit 1; }
I="$(sed -n 1p /tmp/nixout.txt)"
bash tools/gc-keep-current.sh >/dev/null 2>&1 || true
exec bash tools/target-android-gate.sh "$I" oneplus10pro
