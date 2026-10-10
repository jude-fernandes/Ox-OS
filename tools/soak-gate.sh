#!/bin/sh
# Suspend soak gate: boot the payload and let the idle-doze regime run
# unattended; require powerd to complete TARGET suspend/resume cycles
# with zero kernel panics/oopses. Runs for hours by design (overnight).
# usage: soak-gate.sh PAYLOAD_DIR KERNEL [TARGET] [TMO_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TARGET="${3:-1000}"; TMO="${4:-28800}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-soakgate
LOG="$OUT/serial-soak.log"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-soak] %s\n' "$*"; }
fail() { printf '[ox-soak] FAIL: %s\n' "$*" >&2; exit 1; }

(OX_GFX=0 OX_VERBOSE=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

say "soak started: target $TARGET suspend/resume cycles, TMO ${TMO}s"

# wait for the boot to settle first
sleep 60
it=0
while true; do
    N=$(grep -ao "name=pm-resumed n=[0-9]*" "$LOG" 2>/dev/null | tail -1 | sed 's/.*n=//')
    N="${N:-0}"
    ERRS=$(grep -aic "kernel panic\|Oops:" "$LOG" 2>/dev/null || true)
    ERRS="${ERRS:-0}"
    if [ "${ERRS}" -gt 0 ] 2>/dev/null; then
        grep -a -m2 "kernel panic\|Oops:" "$LOG" | sed 's/^/[ox-soak]   /'
        pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
        fail "kernel error detected during soak (count=$ERRS)"
    fi
    if [ "$N" -ge "$TARGET" ] 2>/dev/null; then
        break
    fi
    it=$((it + 1))
    if [ "$it" -gt 600 ]; then
        say "last cycle count: $N"
        fail "soak did not reach $TARGET cycles within the time budget"
    fi
    if [ $((it % 10)) -eq 0 ]; then
        say "progress: $N/$TARGET cycles, errors=$ERRS"
    fi
    sleep 60
done

say "progress: reached $N cycles, errors=0"
grep -a "name=pm-resumed" "$LOG" | tail -1 | sed 's/^/[ox-soak]   /'
pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — $N suspend/resume cycles with zero kernel errors"
echo "SUSPEND SOAK GATE ALL GREEN (cycles=$N)"
