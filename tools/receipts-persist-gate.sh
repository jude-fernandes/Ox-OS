#!/bin/sh
# Cross-reboot receipt persistence: boot 1 records a payment receipt on the
# data volume (via the existing pay gate); the VM is then power-cycled and
# boot 2 — same data.img, fresh machine — must list the old receipt back
# alongside the new one.
# usage: receipts-persist-gate.sh   (builds nothing itself; nix provides)
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
sed -i 's/\r$//' tools/pay-gate.sh targets/qemu-virt-aarch64/run-qemu.sh

say() { printf '[ox-persist] %s\n' "$*"; }
fail() { printf '[ox-persist] FAIL: %s\n' "$*" >&2; exit 1; }

"$NIX" build -L .#guest-daemons .#kernel-qemu --no-link --print-out-paths > /tmp/ox-nix-paths
K="$(sed -n 2p /tmp/ox-nix-paths)/Image"
"$NIX" build -L .#payload-qemu --no-link --print-out-paths > /tmp/ox-nix-paths2
P="$(sed -n 1p /tmp/ox-nix-paths2)"

rm -rf /tmp/ox-persist-payload && mkdir -p /tmp/ox-persist-payload
cp -r "$P"/. /tmp/ox-persist-payload/

say "boot 1: record a receipt (pay gate)"
bash tools/pay-gate.sh /tmp/ox-persist-payload "$K"
TS="$(grep -a 'ox-pay receipts:' /tmp/ox-pay/serial-pay.log | tail -1 | sed 's/.*"ts":\([0-9][0-9]*\).*/\1/')"
[ -n "$TS" ] || fail "no ts in boot-1 receipt"
say "boot-1 receipt ts=$TS"

say "flush margin before power-off"
sleep 20

# boot 2: fresh VM, same data.img
OUT=/tmp/ox-persist2
LOG="$OUT/serial2.log"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon
(OX_GFX=1 timeout 420 bash targets/qemu-virt-aarch64/run-qemu.sh \
    /tmp/ox-persist-payload "$K" "$LOG" >/dev/null 2>&1 &)

i=0
while [ $i -lt 120 ]; do
    grep -q "name=payment-confirm-shown" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -q "name=payment-confirm-shown" "$LOG" || {
    tail -6 "$LOG" 2>/dev/null || true; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
    fail "boot 2: no confirmation card"; }

send_a() {
    python3 - <<'PYEOF'
import socket, time
s = socket.socket(socket.AF_UNIX)
s.connect("/tmp/ox-qmon")
s.settimeout(2)
def drain():
    try:
        return s.recv(65536).decode(errors="replace")
    except socket.timeout:
        return ""
drain()
s.send(b"sendkey a\n")
time.sleep(0.2)
drain()
s.close()
PYEOF
}
n=1
while [ "$n" -le 5 ]; do
    grep -q "name=payment-authorized" "$LOG" 2>/dev/null && break
    send_a
    say "sent 'a' [attempt $n]"
    w=0
    while [ "$w" -lt 8 ]; do
        grep -q "name=payment-authorized" "$LOG" 2>/dev/null && break
        sleep 1; w=$((w + 1))
    done
    n=$((n + 1))
done
grep -q "name=payment-authorized" "$LOG" || {
    tail -6 "$LOG" 2>/dev/null || true; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
    fail "boot 2: no authorize"; }

j=0
while [ $j -lt 90 ]; do
    grep -q "ox-pay receipts:" "$LOG" 2>/dev/null && break
    sleep 1; j=$((j + 1))
done
pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
LINE="$(grep -a 'ox-pay receipts:' "$LOG" | tail -1)"
[ -n "$LINE" ] || fail "boot 2: no receipts listing"
say "boot 2 listing: $LINE"
N="$(printf '%s' "$LINE" | grep -o '"amount_minor":' | wc -l)"
[ "$N" -ge 2 ] || fail "boot 2 lists only $N receipt(s) — boot-1 receipt did not survive"
printf '%s' "$LINE" | grep -q "\"ts\":$TS" || fail "boot-1 ts=$TS missing from boot-2 listing"
say "ALL GREEN — receipt survived the power cycle (boot-1 ts=$TS listed in boot 2; $N receipts)"
echo "RECEIPT PERSISTENCE MILESTONE COMPLETE"
