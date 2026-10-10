#!/bin/sh
# Build both target image sets (cached after their chunk gates) and run
# the flash-pack gate (loop-backed flash + provisioning round-trip).
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd /root/oxbuild
"$NIX" build .#image-pinephone-pro .#image-fairphone5 --no-link --print-out-paths \
    --option cores 4 --max-jobs 1 \
    2>/tmp/nixerr.txt > /tmp/nixout.txt || { echo "BUILD FAILED"; tail -8 /tmp/nixerr.txt; exit 1; }
PPP="$(sed -n 1p /tmp/nixout.txt)"
FP5="$(sed -n 2p /tmp/nixout.txt)"
bash tools/gc-keep-current.sh >/dev/null 2>&1 || true
exec bash tools/target-flashpack-gate.sh "$PPP" "$FP5"
