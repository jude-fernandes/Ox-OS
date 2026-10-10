#!/bin/sh
set -eu
OX="/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS"
for f in "$OX/ox/README-PHASE1.md" "$OX/docs/process/reports/2026-08-29-nix-image-pipeline.md" "$OX/ox/flake.nix" "$OX/ox/kernel/kernel.nix" "$OX/ox/system/rootfs.nix" "$OX/ox/system/s6-stack.nix" "$OX/ox/system/busybox-guest.nix" "$OX/ox/targets/qemu-virt-aarch64/payload.nix" "$OX/ox/tools/build-payload.sh" "$OX/ox/tools/nix-"*.sh; do
    sed -i 's/\r$//' "$f" 2>/dev/null || true
done
echo "CRLF stripped"
python3 - "$OX/README.md" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = """hermetic Nix build of the guest daemons (deterministic store path, boot-gate verified) are
implemented and tested."""
new = """hermetic Nix builds of the guest daemons AND of the full image pipeline (pinned 6.18.48
kernel, rootfs, verity, ed25519-signed payload — deterministic store paths, boot-gate
verified in QEMU) are implemented and tested."""
assert old in s, "README pattern not found"
s = s.replace(old, new)
open(p, "w", encoding="utf-8", newline="\n").write(s)
print("README status updated")
PYEOF
