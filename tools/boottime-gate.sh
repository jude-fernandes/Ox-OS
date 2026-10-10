#!/bin/sh
# Boot-time budget gate on the Nix-built payload: boot N times, capture the
# serial log, and require the stage2 milestone chain to fit the Phase-1
# budgets every time. TCG numbers are regression guards on THIS reference
# environment only (R-20) — never cited as device performance evidence.
# usage: boottime-gate.sh PAYLOAD_DIR KERNEL [RUNS]
set -eu
PAYLOAD="$1"; KERNEL="$2"; RUNS="${3:-3}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-boottime
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-boottime] %s\n' "$*"; }
fail() { printf '[ox-boottime] FAIL: %s\n' "$*" >&2; exit 1; }

i=1
while [ "$i" -le "$RUNS" ]; do
    LOG="$OUT/serial-run$i.log"
    rm -f "$LOG"
    (timeout 240 bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
        "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

    j=0
    while [ "$j" -lt 90 ]; do
        grep -q "name=userspace-ready" "$LOG" 2>/dev/null && break
        sleep 2; j=$((j + 1))
    done
    grep -q "name=userspace-ready" "$LOG" || {
        tail -5 "$LOG" 2>/dev/null || true
        pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
        fail "run$i: no userspace-ready milestone"; }
    sleep 2
    pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
    sleep 1

    say "run $i:"
    python3 "$OXDIR/tools/boottime-parse.py" "$LOG" \
        --max-total 8 --budget userspace-ready=4 \
        | sed 's/^/[ox-boottime]   /'
    i=$((i + 1))
done

say "ALL GREEN — 3 boots within Phase-1 budgets (TCG reference env, R-20)"
