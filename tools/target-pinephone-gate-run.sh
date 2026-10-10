#!/bin/sh
# Build the PinePhone Pro image artifacts (kernel + U-Boot + signed FIT
# + slot images) and run the host-side target gate. NOTE: no --offline
# on the first run — the uboot/TF-A sources are fetched once, then
# gc-keep-current.sh roots them.
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd /root/oxbuild
"$NIX" build .#image-pinephone-pro --no-link --print-out-paths \
    --option cores 4 --max-jobs 1 \
    2>/tmp/nixerr.txt > /tmp/nixout.txt || { echo "BUILD FAILED"; tail -8 /tmp/nixerr.txt; exit 1; }
I="$(sed -n 1p /tmp/nixout.txt)"
bash tools/gc-keep-current.sh >/dev/null 2>&1 || true
exec bash tools/target-pinephone-gate.sh "$I"
