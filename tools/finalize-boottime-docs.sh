#!/bin/sh
set -eu
for f in "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/docs/process/reports/2026-08-30-boottime-gate.md" \
         "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/README-PHASE1.md" \
         "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/tools/boottime-gate.sh" \
         "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/tools/nix-boottime-run.sh" \
         "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/tools/scout-pipewire.sh"; do
    sed -i 's/\r$//' "$f"
done
echo "CRLF stripped"
