#!/bin/sh
# Build the PinePhone Pro image set (cached) and run the A/B slot-update
# gate (offline capability proof + flash->update->verify lifecycle).
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd /root/oxbuild
"$NIX" build .#image-pinephone-pro --no-link --print-out-paths \
    --option cores 4 --max-jobs 1 \
    2>/tmp/nixerr.txt > /tmp/nixout.txt || { echo "BUILD FAILED"; tail -8 /tmp/nixerr.txt; exit 1; }
I="$(sed -n 1p /tmp/nixout.txt)"
bash tools/gc-keep-current.sh >/dev/null 2>&1 || true
exec bash tools/target-update-gate.sh "$I"
