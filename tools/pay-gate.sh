#!/bin/sh
# Payment confirmation gate: boot the gfx payload; the paydemo service
# simulates one tap at boot (oxctl -> paymentsd -> confirmation card on the
# compositor). Verify the card renders, press 'a' via the QEMU keyboard,
# and require the authorize milestone on the serial log.
# usage: pay-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-420}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-pay
LOG="$OUT/serial-pay.log"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-pay] %s\n' "$*"; }
fail() { printf '[ox-pay] FAIL: %s\n' "$*" >&2; exit 1; }

(OX_GFX=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

# 1. wait for the tap -> confirmation card
i=0
while [ $i -lt 120 ]; do
    grep -q "name=payment-confirm-shown" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -q "name=payment-confirm-shown" "$LOG" || {
    tail -8 "$LOG" 2>/dev/null || true; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
    fail "no payment-confirm-shown milestone (tap/UI chain broken)"; }
say "confirmation card shown:"
grep "name=payment-confirm-shown" "$LOG" | tail -1 | sed 's/^/[ox-pay]   /'
# Settle: the card must be committed and the key-recv registered before the
# key press lands (too early is a silent no-op).
sleep 5

# 2. screendump the card
PPM="$OUT/pay-screendump.ppm"
python3 - "$PPM" <<'PYEOF'
import json, socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect("/tmp/ox-qmp")
f = s.makefile("rw")
f.readline()
def send(c):
    f.write(json.dumps(c) + "\n"); f.flush()
    return json.loads(f.readline())
send({"execute": "qmp_capabilities"})
send({"execute": "system_wakeup"})
time.sleep(2.0)
r = send({"execute": "screendump", "arguments": {"filename": sys.argv[1]}})
assert "error" not in r, r
print("[ox-pay] screendump ok")
PYEOF

# 3. accept via the compositor keyboard — retry: the boot-time power
# self-test suspends the machine for ~8 s and keys pressed while frozen are
# lost; a press after resume still reaches the pending key-recv.
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
    say "sent 'a' (accept) [attempt $n]"
    w=0
    while [ "$w" -lt 8 ]; do
        grep -q "name=payment-authorized" "$LOG" 2>/dev/null && break
        sleep 1; w=$((w + 1))
    done
    n=$((n + 1))
done

# 4. require the authorize milestone
j=0
while [ $j -lt 30 ]; do
    grep -q "name=payment-authorized" "$LOG" 2>/dev/null && break
    sleep 1; j=$((j + 1))
done
grep -q "name=payment-authorized" "$LOG" || {
    tail -8 "$LOG" 2>/dev/null || true; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
    fail "no payment-authorized milestone (key routing or ledger failed)"; }
# 4b. durable receipts: the wallet writes the payment to /data and the
# paydemo client lists it back over IPC
k=0
while [ $k -lt 60 ]; do
    grep -q "name=receipt-recorded" "$LOG" 2>/dev/null \
        && grep -q "ox-pay receipts:" "$LOG" 2>/dev/null && break
    sleep 1; k=$((k + 1))
done
grep -q "name=receipt-recorded" "$LOG" || {
    tail -8 "$LOG" 2>/dev/null || true; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
    fail "no receipt-recorded milestone (durable write failed)"; }
grep -q "ox-pay receipts:" "$LOG" || {
    tail -8 "$LOG" 2>/dev/null || true; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
    fail "paydemo did not list the receipt back (receipt IPC failed)"; }
grep -q "name=wake-lock-acquire id=paymentsd-confirm" "$LOG" || {
    tail -8 "$LOG" 2>/dev/null || true; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
    fail "no wake lock during confirmation (idle doze can kill the flow)"; }
say "wake lock held during confirmation"
say "durable receipt:"
grep "name=receipt-recorded" "$LOG" | tail -1 | sed 's/^/[ox-pay]   /'
grep "ox-pay receipts:" "$LOG" | tail -1 | sed 's/^/[ox-pay]   /'
pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1

# 5. artifact sanity: screen alive, PNG saved
python3 - "$PPM" "$OUT/pay-screendump.png" <<'PYEOF'
import sys
path, png = sys.argv[1], sys.argv[2]
with open(path, "rb") as f:
    assert f.read(3).strip() == b"P6"
    dims = []
    while len(dims) < 2:
        line = f.readline()
        if line.startswith(b"#"):
            continue
        dims += [int(x) for x in line.split()]
    w, h = dims[:2]
    f.readline()
    data = f.read()
lit = sum(1 for i in range(0, len(data), 3) if data[i] or data[i+1] or data[i+2])
print(f"[ox-pay] framebuffer {w}x{h}, lit-pixel ratio {lit / (w * h):.4f}")
assert lit / (w * h) > 0.5, "scanout dead"
import struct, zlib
def chunk(tag, payload):
    c = struct.pack(">I", len(payload)) + tag + payload
    return c + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
raw = b"".join(b"\x00" + data[y*w*3:(y+1)*w*3] for y in range(h))
with open(png, "wb") as out:
    out.write(b"\x89PNG\r\n\x1a\n"
              + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
              + chunk(b"IDAT", zlib.compress(raw, 6))
              + chunk(b"IEND", b""))
print(f"[ox-pay] wrote {png}")
PYEOF
say "ALL GREEN — tap -> wallet card -> user accept -> authorized -> durable receipt"
