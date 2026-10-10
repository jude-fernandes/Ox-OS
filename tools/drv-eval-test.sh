#!/bin/sh
# one-shot: reproduce the drv eval exactly as gc-keep-current runs it
set -e
cd /root/oxbuild
N=/nix/var/nix/profiles/per-user/root/profile/bin/nix
DRV=$($N eval --raw ".#payload-qemu.drvPath" 2>/tmp/drvtest-err.txt) || { echo EVAL_FAILED; cat /tmp/drvtest-err.txt; exit 1; }
echo "DRV_OK: $DRV"
