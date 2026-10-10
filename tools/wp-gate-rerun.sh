#!/bin/sh
# Re-run the wireplumber gate against the already-built payload (no
# rebuild): confirmation boot for reproducibility.
set -eu
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
P="$(sed -n 1p /tmp/nixout.txt)"
K="$(sed -n 2p /tmp/nixout.txt)/Image"
bash tools/wireplumber-gate.sh /tmp/ox-wpg-payload "$K"
