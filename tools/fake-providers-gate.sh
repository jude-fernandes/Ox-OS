#!/bin/sh
# Fake-providers gate: the honest-permission modes across the location
# and messages services, end to end. locationd and messagesd consult
# permstored per app: deny -> refused, fake -> SYNTHETIC data served,
# grant -> real store (location on a GNSS-less device answers "no fix"
# honestly). The boot selftest walks all three modes for
# location.test and messages.test; the gate requires every leg
# journaled plus the consult trail.
# usage: fake-providers-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-900}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-fpgate
LOG="$OUT/serial-fakeprov.log"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-fp] %s\n' "$*"; }
fail() { printf '[ox-fp] FAIL: %s\n' "$*" >&2; exit 1; }

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
wait_ms "name=locationd-ready" 120 "locationd did not start"
wait_ms "name=messagesd-ready" 120 "messagesd did not start"
wait_ms "name=shell-home" 150 "shell did not draw"
say "locationd + messagesd + shell up"

# 2. location: the three modes, journaled and proven by the selftest
wait_ms "name=location-consult app=oxctl mode=deny" 120 "location deny consult not journaled"
say "location deny: consult refused (journal)"
wait_ms "name=location-consult app=oxctl mode=fake" 120 "location fake consult not journaled"
say "location fake: synthetic fix served (journal)"
wait_ms "name=location-consult app=oxctl mode=grant" 120 "location grant consult not journaled"
say "location grant: real store served — no fix on a GNSS-less device (journal)"
wait_ms "name=location-test-ok" 30 "location selftest did not pass"
say "location selftest: deny refused, fake synthetic:true, grant honest no-fix"
grep -a "DBG-LOC-FAKE" "$LOG" | tail -1 | sed 's/^/[ox-fp]   /'
grep -a "DBG-LOC-GRANT" "$LOG" | tail -1 | sed 's/^/[ox-fp]   /'

# 3. messages: the three modes
wait_ms "name=messages-consult app=oxctl mode=deny" 120 "messages deny consult not journaled"
say "messages deny: consult refused (journal)"
wait_ms "name=messages-consult app=oxctl mode=fake" 120 "messages fake consult not journaled"
say "messages fake: synthetic messages served (journal)"
wait_ms "name=messages-consult app=oxctl mode=grant" 120 "messages grant consult not journaled"
say "messages grant: real store served (journal)"
wait_ms "name=messages-test-ok" 30 "messages selftest did not pass"
say "messages selftest: deny refused, fake synthetic:true, grant real"
grep -a "DBG-MSG-FAKE" "$LOG" | tail -1 | sed 's/^/[ox-fp]   /'

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — fake-data providers: location + messages deny/fake/grant all honest, all journaled"
echo "FAKE PROVIDERS GATE ALL GREEN"
