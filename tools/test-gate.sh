#!/bin/sh
# Workspace-test gate: every unit test in the Rust workspace runs
# (host toolchain, Nix sandbox, same vendored deps as the guest build).
# The guest cross-build compiles but never RUNS tests — this gate is
# what makes unit tests count (the grants-panel action-code swap would
# have been caught here). usage: test-gate.sh
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
OUT=$("$NIX" build .#workspace-test --no-link --print-out-paths \
    --option cores 2 --max-jobs 1 \
    2>/tmp/ox-testerr.txt) || { echo "TESTS FAILED"; tail -25 /tmp/ox-testerr.txt; exit 1; }
echo "WORKSPACE TEST GATE ALL GREEN ($OUT)"
