#!/bin/sh
# Resourced gate: boot the payload; require the zram swap tier to come
# up (resourced-zram-ok), the pressure monitor to be ready
# (resourced-ready), and the selftest's tmpfs fill to drive real
# tier1 (drop caches) and tier2 (compact) escalation through PSI
# pressure (resourced-tier-ok).
# usage: resourced-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-1100}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-resgate
LOG="$OUT/serial-res.log"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-res] %s\n' "$*"; }
fail() { printf '[ox-res] FAIL: %s\n' "$*" >&2; exit 1; }

(OX_GFX=0 OX_VERBOSE=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

# 1. zram swap + monitor ready
i=0
while [ $i -lt 90 ]; do
    grep -aq -e "name=resourced-zram-ok" -e "name=resourced-zram-unavailable" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -aq "name=resourced-zram-ok" "$LOG" || {
    tail -12 "$LOG" 2>/dev/null || true
    fail "no resourced-zram-ok milestone (zram swap tier failed)"; }
# kmsg flushes in batches: ready may land a moment after zram-ok.
i=0
while [ $i -lt 60 ]; do
    grep -aq "name=resourced-ready" "$LOG" 2>/dev/null && break
    sleep 1; i=$((i + 1))
done
grep -aq "name=resourced-ready" "$LOG" || fail "no resourced-ready milestone"
say "zram swap tier up (256 MiB) and pressure monitor ready"

# 2. pressure drill: tier1 + tier2 escalation (the chunked drill is
#    bounded at 21 chunks, but each chunk can take ~40 s on a slow
#    TCG run — wait up to 1000 s)
j=0
while [ $j -lt 500 ]; do
    grep -aq -e "name=resourced-tier-ok" -e "name=resourced-tier-failed" "$LOG" 2>/dev/null && break
    sleep 2; j=$((j + 1))
done
grep -aq "name=resourced-tier-ok" "$LOG" || {
    sleep 5; tail -25 "$LOG" 2>/dev/null || true
    fail "no resourced-tier-ok milestone (tmpfs fill did not drive escalation)"; }
say "tier escalation under pressure:"
grep -a -e "resourced tier1" -e "resourced tier2" "$LOG" | grep -a "action=" | head -3 | sed 's/^/[ox-res]   /'
say "selftest evidence:"
grep -a "DBG-PRESS" "$LOG" | tail -2 | sed 's/^/[ox-res]   /'

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — zram swap + PSI tiers escalate under real pressure"
echo "RESOURCED GATE ALL GREEN"
