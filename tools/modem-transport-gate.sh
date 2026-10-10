#!/bin/sh
# Modem transport gate: boot the payload with the virtio-serial "modem
# slot" wired to the host-side AT emulator; require the guest selftest
# to complete the AT init sequence through the transport
# (modem-transport-ok) and the emulator log to show the real queries.
# usage: modem-transport-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-420}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-modemgate
LOG="$OUT/serial-modem.log"
EMU="$OUT/modem-emu.log"
EMUOUT="$OUT/modem-emu.stderr"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon /tmp/ox-modem-emu.sock

say() { printf '[ox-modem] %s\n' "$*"; }
fail() { printf '[ox-modem] FAIL: %s\n' "$*" >&2; exit 1; }

# 1. emulator up first (QEMU connects out to it, with reconnect)
python3 "$OXDIR/tools/modem-emu.py" --sock /tmp/ox-modem-emu.sock \
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

# 2. transport up: the daemon owns the port and completed its init poll
i=0
while [ $i -lt 120 ]; do
    grep -aq -e "name=oxmodemd-up " -e "name=oxmodemd-up-noport" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -aq "name=oxmodemd-up transport=" "$LOG" || {
    tail -20 "$LOG" 2>/dev/null || true
    fail "no oxmodemd-up milestone (modem transport did not come up)"; }
say "modem transport owned by oxmodemd:"
grep -a "name=oxmodemd-up transport=" "$LOG" | tail -1 | sed 's/^/[ox-modem]   /'

# 3. service layer: refresh + status over IPC (identity from the modem)
j=0
while [ $j -lt 60 ]; do
    grep -aq -e "name=oxmodemd-status-ok" -e "name=oxmodemd-status-failed" "$LOG" 2>/dev/null && break
    sleep 2; j=$((j + 1))
done
grep -aq "name=oxmodemd-status-ok" "$LOG" || {
    tail -20 "$LOG" 2>/dev/null || true
    fail "no oxmodemd-status-ok milestone (oxmodemd IPC status failed)"; }
say "oxmodemd status over IPC:"
grep -a "DBG-OXMODEMD" "$LOG" | tail -1 | sed 's/^/[ox-modem]   /'
# the emulator side must show the daemon's init commands arrived
grep -q "AT 'AT+CPIN?'" "$EMU" || fail "emulator never saw AT+CPIN?"
grep -q "AT 'AT+CSQ'" "$EMU" || fail "emulator never saw AT+CSQ?"
say "emulator answered the init sequence (EG25-G personality):"
grep -a -e "AT+CPIN?" -e "AT+CSQ" "$EMU" | tail -2 | sed 's/^/[ox-modem]   /'

# 4. SMS through the daemon (two-phase CMGS behind the policy layer)
k=0
while [ $k -lt 60 ]; do
    grep -aq -e "name=modem-sms-ok" -e "name=modem-sms-failed" "$LOG" 2>/dev/null && break
    sleep 2; k=$((k + 1))
done
grep -aq "name=modem-sms-ok" "$LOG" || {
    tail -20 "$LOG" 2>/dev/null || true
    fail "no modem-sms-ok milestone (SMS send over IPC failed)"; }
grep -aq 'SMS-SENT to +15550001' "$EMU" || fail "emulator never received the SMS"
say "SMS via daemon (egress-journaled, two-phase CMGS):"
grep -a "DBG-SMS" "$LOG" | tail -1 | sed 's/^/[ox-modem]   /'
grep -a "SMS-SENT" "$EMU" | tail -1 | sed 's/^/[ox-modem]   /'

kill "$EMU_PID" 2>/dev/null || true
pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — modem slot transport + oxmodemd service layer verified end to end"
echo "MODEM TRANSPORT GATE ALL GREEN"
