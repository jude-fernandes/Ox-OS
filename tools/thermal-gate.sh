#!/bin/sh
# Thermal gate: boot the payload; require thermald up and the selftest
# to drive the temperature source through warn -> hot -> critical with
# hysteresis-gated escalation (thermald-tier-ok).
# usage: thermal-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-600}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-thermgate
LOG="$OUT/serial-thm.log"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-thm] %s\n' "$*"; }
fail() { printf '[ox-thm] FAIL: %s\n' "$*" >&2; exit 1; }

(OX_GFX=0 OX_VERBOSE=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

# 1. daemon up
i=0
while [ $i -lt 90 ]; do
    grep -aq "name=thermald-ready" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -aq "name=thermald-ready" "$LOG" || {
    tail -12 "$LOG" 2>/dev/null || true
    fail "no thermald-ready milestone"; }
say "thermald up (source: virtual-target file, policy live)"

# 2. policy drill: warn -> hot -> critical
j=0
while [ $j -lt 300 ]; do
    grep -aq -e "name=thermald-tier-ok" -e "name=thermald-tier-failed" "$LOG" 2>/dev/null && break
    sleep 2; j=$((j + 1))
done
grep -aq "name=thermald-tier-ok" "$LOG" || {
    sleep 5; tail -20 "$LOG" 2>/dev/null || true
    fail "no thermald-tier-ok milestone (policy drill failed)"; }
say "tier transitions:"
grep -a "name=thermald-warn\|name=thermald-hot\|name=thermald-critical" "$LOG" | tail -3 | sed 's/^/[ox-thm]   /'
say "selftest evidence:"
grep -a "DBG-THERM" "$LOG" | tail -3 | sed 's/^/[ox-thm]   /'

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — thermal policy warn/hot/critical with hysteresis"
echo "THERMAL GATE ALL GREEN"
