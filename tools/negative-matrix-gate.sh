#!/bin/sh
# Negative-matrix gate: the Phase-3 exit criterion "permission bypass
# negative matrix green", consolidated into ONE boot. Ten bypass
# attempts, one per row, all must be refused:
#   1  permstored   unbound app reads deny
#   2  notifd       unbound post refused
#   3  contactsd    unbound contact list refused
#   4  locationd    unbound location fix refused
#   5  messagesd    unbound message list refused
#   6  intentd      corrupted package refused
#   7  intentd      valid-manifest + WRONG SIGNATURE refused
#   8  intentd      unpackaged app start refused
#   9  intentd      nonexistent app removal refused
#   10 lockd        wrong PIN rejected
# Unit-level refusals (ox-files path-sandbox escape, manifest
# validation, bin traversal) run in the workspace test gate.
# usage: negative-matrix-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-900}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-nmg
LOG="$OUT/serial-matrix.log"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-nm] %s\n' "$*"; }
fail() { printf '[ox-nm] FAIL: %s\n' "$*" >&2; exit 1; }

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1

(OX_GFX=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

wait_ms() {
    _pat="$1"; _max="$2"; _label="$3"
    k=0
    while [ $k -lt "$_max" ]; do
        grep -aq "$_pat" "$LOG" 2>/dev/null && return 0
        if [ $((k % 10)) -eq 5 ]; then
            # PM wake assist: nudge the machine like a power button —
            # the RTC alarm can miss under host load (guest clock lag
            # arms the wakealarm in the past); no-op while awake.
            python3 - <<'PYW' 2>/dev/null || true
import socket
try:
    s = socket.socket(socket.AF_UNIX)
    s.connect("/tmp/ox-qmon")
    s.settimeout(2)
    s.recv(4096)
    s.sendall(b"system_wakeup\n")
except Exception:
    pass
PYW
        fi
        sleep 2; k=$((k + 1))
    done
    fail "$_label (pattern not observed: $_pat)"
}

wait_ms "name=matrix-ok rows=10" 150 "negative matrix did not pass"

# print the matrix for the report
say "permission bypass negative matrix — ALL ROWS REFUSED:"
n=1
while [ $n -le 10 ]; do
    grep -a "DBG-MATRIX-$n " "$LOG" | tail -1 | sed 's/^/[ox-nm]   /'
    n=$((n + 1))
done
grep -aq "matrix-.*-FAILED\|name=matrix-failed" "$LOG" && fail "a matrix row failed" || true

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — negative matrix: 10/10 bypass attempts refused, fail-closed everywhere"
echo "NEGATIVE MATRIX GATE ALL GREEN"
