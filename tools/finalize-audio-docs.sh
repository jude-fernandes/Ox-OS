#!/bin/sh
set -eu
python3 - "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/docs/process/risk-register.md" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
anchor = "| R-25 |"
idx = s.index(anchor)
line_end = s.index("\n", idx)
new_row = "\n| R-26 | s6-rc ONESHOTS never run under the direct s6-svscan fallback (R-21 corollary): the fallback supervises compiled/servicedirs/ (longruns only), so any service defined as a oneshot silently does not execute on the virtual target (discovered 2026-08-30 via audio-selftest) | Boot/CI | Medium | Boot | Document longrun-only rule for virtual-target services; convert needed oneshots to park-after-action longruns; retest oneshots under KVM when R-21 resolves | Accepted interim | Phase 2 |"
s = s[:line_end] + new_row + s[line_end:]
open(p, "w", encoding="utf-8", newline="\n").write(s)
print("R-26 appended")
PYEOF
for f in "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/docs/process/risk-register.md" \
         "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/docs/process/reports/2026-08-30-audio-bringup.md" \
         "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/README-PHASE1.md" \
         "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/system/s6-rc-source/audio-selftest/run" \
         "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/tools/audio-gate.sh" \
         "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/tools/nix-audio-rerun.sh" \
         "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/tools/nix-audio-chain.sh" \
         "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/system/snd-test.nix" \
         "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/system/snd-test/ox-snd-test.c" \
         "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/system/rootfs.nix" \
         "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/flake.nix" \
         "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/kernel/kernel.nix" \
         "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/targets/qemu-virt-aarch64/payload.nix"; do
    sed -i 's/\r$//' "$f"
done
echo "docs updated + CRLF stripped"
