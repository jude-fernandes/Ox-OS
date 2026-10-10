#!/bin/sh
# PipeWire milestone scout (v6): build the lean audio-only pipewire from
# tools/pipewire-lean.nix (-f mode: no shell quoting of the nix expr).
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
LOG=/tmp/pipewire-build.log
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "== building pipewire (lean, -f mode) =="
if "$NIX" build -L --impure -f "$DIR/pipewire-lean.nix" --no-link --print-out-paths \
    --option cores 2 --max-jobs 1 > /tmp/pw-out.txt 2>"$LOG"; then
    OUT="$(tail -1 /tmp/pw-out.txt)"
else
    echo "BUILD FAILED — last 20 log lines:"
    tail -20 "$LOG"
    exit 1
fi
echo "out: $OUT"

echo "== version =="
"$OUT/bin/pw-cli" --version 2>/dev/null || true

echo "== closure total =="
"$NIX" path-info -rsh "$OUT" | awk '{s+=$2} END {printf "%.1f MiB across %d paths\n", s/1048576, NR}'

echo "== largest closure paths =="
"$NIX" path-info -rsh "$OUT" | sort -k2 -h | tail -8

echo "== key binaries =="
ls "$OUT/bin" 2>/dev/null

echo "== spa plugins =="
ls "$OUT/lib/spa-0.2" 2>/dev/null | head -8
