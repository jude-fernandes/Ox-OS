#!/bin/sh
. "$(dirname "$0")/gate-lib.sh"   # chunk-54 guest-time waits
# Messages-store gate (Phase 4): the real telephony writer behind the
# Phase-3 synthetic-store contract. The gate injects an inbound SMS
# through the emulator's control socket and requires the full chain:
# oxmodemd reads it off the radio (CMTI->CMGR) -> messagesd's ingest
# thread appends it to the REAL store (/data/ox/messages.json,
# journaled messages-ingested) -> an on-guest selftest walks the
# honest permission matrix against that data: DENY refused, FAKE
# clearly synthetic (and NOT leaking the real text), GRANT returns
# the injected SMS VERBATIM (synthetic:false, dir=in, from +15550042).
# The sent leg is proven by the boot selftest's own system-path SMS
# landing as dir=out.
# usage: messages-store-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-1200}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-msgstoregate
LOG="$OUT/serial-msgstore.log"
EMU="$OUT/modem-emu.log"
EMUOUT="$OUT/modem-emu.stderr"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon /tmp/ox-modem-emu.sock /tmp/ox-modem-emu-ctl

say() { printf '[ox-mstore] %s\n' "$*"; }
fail() { printf '[ox-mstore] FAIL: %s\n' "$*" >&2; exit 1; }

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

# the AT emulator up first (control socket for the injection)
python3 "$OXDIR/tools/modem-emu.py" --sock /tmp/ox-modem-emu.sock \
    --ctl /tmp/ox-modem-emu-ctl \
    --log "$EMU" > "$EMUOUT" 2>&1 &
EMU_PID=$!
sleep 1
kill -0 "$EMU_PID" 2>/dev/null || fail "modem emulator did not start"
trap 'kill "$EMU_PID" 2>/dev/null || true; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true' EXIT

(OX_KERNEL_EXTRA=" ox.pm_drill=off" OX_GFX=0 OX_VERBOSE=1 OX_QEMU_EXTRA="-chardev socket,id=oxmodem,path=/tmp/ox-modem-emu.sock,server=off,reconnect=3 \
    -device virtio-serial-pci,id=oxser \
    -device virtserialport,chardev=oxmodem,name=oxmodem.0" \
    timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

# 1. the modem transport comes up; messagesd and the selftests boot
wait_guest "name=oxmodemd-up transport=" 720000 1800 "oxmodemd never found the modem transport"
say "modem transport up; waiting for the boot selftest SMS to ingest"
# the modem-selftest's system-path boot send must land as dir=out —
# proof the ingest covers the SENT leg without any UI
wait_guest "messages-ingested dir=out number=+15550001" 360000 1800 "sent leg never ingested (store writer broken?)"
say "sent SMS ingested into the real store (dir=out)"

# 2. inject the inbound SMS; the radio -> daemon -> store chain must land
python3 "$OXDIR/tools/modem-inject.py" /tmp/ox-modem-emu-ctl \
    +15550042 "the eagle lands at dawn" > /dev/null
say "inbound SMS injected (+15550042)"
grep -aq "SMS-INJECT idx=1 from=+15550042" "$EMU" || fail "emulator never stored the message"
wait_guest "modem-sms-received from=+15550042" 360000 1800 "daemon never read the delivered SMS"
wait_guest "messages-ingested dir=in number=+15550042" 360000 1800 "messagesd never appended the SMS to the real store"
say "inbound SMS landed in the real store (dir=in)"

# 3. the on-guest selftest walks deny/fake/grant against that data
wait_guest "name=messages-real-sms-ok" 720000 1800 "selftest never verified the matrix (deny/fake/grant over REAL data)"
say "permission matrix over REAL data: deny refused, fake synthetic (no leak), grant verbatim"

# 4. the legacy fake-providers contract must STILL conclude: this gate
#    adds a second permstored walker, and a same-row race here once
#    wedged fake-providers before its verdicts (chunk-41 finding)
wait_guest "name=messages-test-ok" 360000 1800 "fake-providers messages verdict never fired (permstored row race?)"
wait_guest "name=location-test-ok" 360000 1800 "fake-providers location verdict never fired"
say "legacy fake-providers contract still green alongside the new walker"

kill "$EMU_PID" 2>/dev/null || true
pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — messages store: network SMS -> daemon inbox -> messagesd ingest -> granted apps read the REAL message verbatim; deny/fake never leak it; sent leg ingested too"
echo "MESSAGES STORE GATE ALL GREEN"
