#!/bin/sh
L="/mnt/c/Users/rawc1/.zcode/cli/exec/sess_83ed70c0-c41a-4aeb-b80e-d1d448cd4873/call_0c674b83c9df4901a2c81faf-stdout.log"
echo "== chain log lines: $(wc -l < "$L" 2>/dev/null || echo 0)"
grep -aE "^== |kernel: |payload: |FAIL|error:" "$L" 2>/dev/null | tail -6
echo "== what is running =="
ps aux | grep -E "nix-build|nix build|make|cc1|qemu-system" | grep -v grep | head -6 | cut -c1-140
echo "== cc1 count =="
ps aux | grep -c "cc1 " || true
echo "== uptime/load =="
uptime
