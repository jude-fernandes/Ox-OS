#!/bin/sh
# Network gate: boot the payload with virtio-net on user-mode slirp;
# require netd to bring the interface up, resolve a name through its
# own DNS forwarder against the host-side deterministic DNS responder,
# and refuse a canary name by policy — with the host responder's log
# proving which queries actually left the guest.
# usage: network-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-300}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-netgate
LOG="$OUT/serial-net.log"
DNSEMU="$OUT/dns-emu.log"
EMUOUT="$OUT/dns-emu.stderr"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-net] %s\n' "$*"; }
fail() { printf '[ox-net] FAIL: %s\n' "$*" >&2; exit 1; }

# 1. deterministic host DNS responder first
pkill -f net-dns-emu.py >/dev/null 2>&1 || true
sleep 1
python3 "$OXDIR/tools/net-dns-emu.py" --bind 127.0.0.1 --port 53 \
    --log "$DNSEMU" > "$EMUOUT" 2>&1 &
EMU_PID=$!
sleep 1
kill -0 "$EMU_PID" 2>/dev/null || fail "host DNS responder did not start"
trap 'kill "$EMU_PID" 2>/dev/null || true; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true' EXIT

(OX_GFX=0 OX_VERBOSE=1 OX_QEMU_EXTRA="-nic user,model=virtio-net-pci" \
    timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

# 2. interface up
i=0
while [ $i -lt 90 ]; do
    grep -aq -e "name=netd-up" -e "name=netd-no-iface" -e "netd-up-incomplete" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -aq "name=netd-up" "$LOG" || {
    tail -12 "$LOG" 2>/dev/null || true
    fail "no netd-up milestone (interface bring-up failed)"; }
say "interface bring-up:"
grep -a "name=netd-up" "$LOG" | tail -1 | sed 's/^/[ox-net]   /'

# 3. DNS resolution through the forwarder (journaled egress)
i=0
while [ $i -lt 60 ]; do
    grep -aq -e "name=netd-dns-ok" -e "name=netd-dns-failed" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -aq "name=netd-dns-ok" "$LOG" || {
    sleep 5; tail -20 "$LOG" 2>/dev/null || true
    fail "no netd-dns-ok milestone (DNS resolution through netd failed)"; }
say "DNS resolution through netd (egress-journaled):"
grep -a "dns journal" "$LOG" | head -4 | sed 's/^/[ox-net]   /'

# 4. policy refusal (canary) — refused in-guest, never reached the host
grep -aq "name=netd-policy-ok" "$LOG" || {
    sleep 5; tail -20 "$LOG" 2>/dev/null || true
    fail "no netd-policy-ok milestone (canary refusal failed)"; }
if grep -aq "canary.refused.ox" "$DNSEMU"; then
    fail "canary query LEAKED to the host responder (policy not enforced)"
fi
say "policy refusal enforced in-guest; host responder never saw the canary"

# 5. host responder cross-check: the real query arrived
grep -q "QUERY ox-gate.test" "$DNSEMU" || fail "host responder never saw the ox-gate.test query"
say "host responder received the forwarded query:"
grep -a "QUERY" "$DNSEMU" | tail -2 | sed 's/^/[ox-net]   /'

kill "$EMU_PID" 2>/dev/null || true
pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — netd bring-up + journaled DNS + name policy enforced"
echo "NETWORK GATE ALL GREEN"
