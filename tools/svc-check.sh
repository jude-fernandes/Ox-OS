#!/bin/sh
# diagnostic: per-service file names in the rootfs source snapshot
SRC=/nix/store/vy08wm9asbzn6c5m6wv57h0mllzf5p14-source/system/s6-rc-source
for d in acl-selftest boot-health-selftest oxcom permstored slot-confirm getty-ttyAMA0 default; do
    echo "== $d: $(ls "$SRC/$d" 2>&1 | tr '\n' ' ')"
done
echo "=== how many services have up vs run (whole snapshot):"
cd "$SRC" || exit 1
UP=0; RUN=0
for d in */; do
    [ -f "$d/up" ] && UP=$((UP + 1))
    [ -f "$d/run" ] && RUN=$((RUN + 1))
done
echo "dirs with up: $UP dirs with run: $RUN"; for d in */; do [ -f "$d/up" ] && echo "UP-DIR: $d"; done
