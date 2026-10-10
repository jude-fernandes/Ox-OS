#!/bin/sh
# Notification/permission gate: TWO boots.
#   boot 1: permstored up, notifd flow green (grant -> post accepted ->
#           listed -> stranger refused -> fake mode stored)
#   boot 2: the grant SURVIVED the reboot (permstored-loaded with
#           grants >= 1) and the flow is green again.
# usage: notification-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-420}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-notifgate

say() { printf '[ox-notif] %s\n' "$*"; }
fail() { printf '[ox-notif] FAIL: %s\n' "$*" >&2; exit 1; }

boot_and_wait() {
    local LOG="$1"
    rm -rf "$(dirname "$LOG")-tmp" 2>/dev/null || true
    (OX_GFX=0 OX_VERBOSE=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
        "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)
    i=0
    while [ $i -lt 90 ]; do
        grep -aq "name=permstored-loaded" "$LOG" 2>/dev/null && \
        grep -aq "name=notifd-ready" "$LOG" 2>/dev/null && break
        sleep 2; i=$((i + 1))
    done
    grep -aq "name=permstored-loaded" "$LOG" || {
        tail -10 "$LOG" 2>/dev/null || true
        fail "permstored did not come up"; }
    grep -aq "name=notifd-ready" "$LOG" || {
        tail -10 "$LOG" 2>/dev/null || true
        fail "notifd did not come up"; }
}

wait_flow() {
    local LOG="$1"
    i=0
    while [ $i -lt 120 ]; do
        grep -aq -e "name=notifd-flow-ok" -e "name=notifd-flow-failed" "$LOG" 2>/dev/null && break
        sleep 2; i=$((i + 1))
    done
    grep -aq "name=notifd-flow-ok" "$LOG" || {
        tail -25 "$LOG" 2>/dev/null || true
        fail "notifd flow failed"; }
}

# --- boot 1 ---
LOG1="$OUT/serial-notif1.log"
mkdir -p "$OUT"
boot_and_wait "$LOG1"
say "boot 1: permstored + notifd up"
wait_flow "$LOG1"
say "boot 1: flow green (grant -> post -> list -> stranger refused -> fake stored)"
grep -a "name=permstored-loaded" "$LOG1" | tail -1 | sed 's/^/[ox-notif]   /'
grep -a -e "DBG-POST" -e "DBG-DENY" "$LOG1" | tail -2 | sed 's/^/[ox-notif]   /'

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 2

# --- boot 2 (same payload clone: /data persists) ---
LOG2="$OUT/serial-notif2.log"
boot_and_wait "$LOG2"
LOADED=$(grep -a "name=permstored-loaded" "$LOG2" | tail -1)
say "boot 2: $LOADED"
GRANTS=$(printf '%s' "$LOADED" | sed -n 's/.*grants=\([0-9]*\).*/\1/p')
[ -n "$GRANTS" ] && [ "$GRANTS" -ge 1 ] 2>/dev/null || {
    pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
    fail "grant did not survive the reboot (permstored-loaded grants<1)"; }
say "grant survived the reboot (grants=$GRANTS at load)"
wait_flow "$LOG2"
say "boot 2: flow green again"

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — permission-checked notifications + grants survive reboot"
echo "NOTIFICATION GATE ALL GREEN"
