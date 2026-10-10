#!/bin/sh
# Build-only PinePhone Pro image artifacts (no gate) — the iteration
# companion of target-pinephone-gate-run.sh. First run fetches the
# uboot/TF-A sources; the rk3399 kernel cross-build dominates.
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd /root/oxbuild
"$NIX" build .#image-pinephone-pro --no-link --print-out-paths \
    --option cores 4 --max-jobs 1 \
    2>/tmp/nixerr.txt > /tmp/nixout.txt
echo "BUILD OK"
cat /tmp/nixout.txt
