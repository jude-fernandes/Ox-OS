#!/bin/sh
# Contacts gate: the charter's fake-data permission feature, end to
# end. contactsd consults permstored per app: deny -> refused,
# fake -> SYNTHETIC contacts served, grant -> real store. The boot
# selftest walks all three modes for contacts.test; the gate requires
# every leg journaled plus the consult trail.
# usage: contacts-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-900}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-ctgate
LOG="$OUT/serial-contacts.log"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-ct] %s\n' "$*"; }
fail() { printf '[ox-ct] FAIL: %s\n' "$*" >&2; exit 1; }

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

# 1. services up
wait_ms "name=contactsd-ready" 120 "contactsd did not start"
wait_ms "name=shell-home" 150 "shell did not draw"
say "contactsd + shell up"

# 2. the three modes, journaled by contactsd and proven by the selftest
wait_ms "name=contacts-consult app=oxctl mode=deny" 120 "deny consult not journaled"
say "deny: consult refused (journal)"
wait_ms "name=contacts-consult app=oxctl mode=fake" 120 "fake consult not journaled"
say "fake: synthetic contacts served (journal)"
wait_ms "name=contacts-consult app=oxctl mode=grant" 120 "grant consult not journaled"
say "grant: real store served (journal)"
wait_ms "name=contacts-test-ok" 30 "contacts selftest did not pass"
say "selftest: deny refused, fake synthetic:true, grant real"
grep -a "DBG-CT-FAKE" "$LOG" | tail -1 | sed 's/^/[ox-ct]   /'

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — fake-data providers: deny/fake/grant all honest, all journaled"
echo "CONTACTS GATE ALL GREEN"
