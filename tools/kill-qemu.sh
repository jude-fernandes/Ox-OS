#!/bin/sh
# Kill stray QEMU from interrupted gate runs. This script's own cmdline
# does not contain the pattern beyond this line (pkill self-match guard:
# the literal is assembled so it does not appear in argv of this script).
PAT="qemu-system-aarch64"
for pid in $(pgrep -f "$PAT" 2>/dev/null); do
    [ "$pid" = "$$" ] && continue
    kill "$pid" 2>/dev/null || true
done
sleep 1
pgrep -f "$PAT" >/dev/null 2>&1 && echo "stray qemu still present" || echo "no qemu running"
