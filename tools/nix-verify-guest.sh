#!/bin/sh
# Verify the Nix-built guest daemons: architecture, static linking, and
# determinism (a second nix build must be a no-op).
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"

OUT=$(readlink result)
echo "store path: $OUT"
echo "== file(1) on all five binaries =="
for b in oxcom oxpaymentsd ox-status inputd powerd; do
    file "$OUT/bin/$b"
done
echo "== rebuild determinism (second build must be a no-op) =="
nix build -L .#guest-daemons 2>&1 | tail -2
echo "second build store path: $(readlink result)"
[ "$(readlink result)" = "$OUT" ] && echo "DETERMINISTIC: same store path" || echo "NONDETERMINISTIC"
