#!/bin/sh
# Probe: does QMP input-send-event reach the guest pointer stack?
set -eu
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-pointerprobe
LOG="$OUT/serial-probe.log"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon
P=/tmp/ox-shg-payload
K=/tmp/ox-soakg-payload/../ox-soakg-payload # unused; kernel passed below
KERNEL=/tmp/nix-kernel/Image
ls "$KERNEL" >/dev/null 2>&1 || { echo "no kernel at $KERNEL"; exit 1; }

(OX_GFX=1 timeout 240 bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$P" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

i=0
while [ ! -S /tmp/ox-qmp ] && [ $i -lt 60 ]; do
    sleep 1; i=$((i + 1))
done
sleep 4
echo "--- inject attempt A ---"
python3 - <<'PYEOF'
import json, socket, time
s = socket.socket(socket.AF_UNIX); s.connect("/tmp/ox-qmp")
f = s.makefile("rw"); f.readline()
def send(c):
    f.write(json.dumps(c) + "\n"); f.flush()
    return json.loads(f.readline())
send({"execute": "qmp_capabilities"})
def ev(events):
    r = send({"execute": "input-send-event", "arguments": {"events": events}})
    print("ev:", r)
    time.sleep(0.2)
ev([{"type": "abs", "data": {"axis": "x", "value": 20000}},
    {"type": "abs", "data": {"axis": "y", "value": 20000}}])
ev([{"type": "abs", "data": {"axis": "x", "value": 10000}},
    {"type": "abs", "data": {"axis": "y", "value": 10000}}])
ev([{"type": "btn", "data": {"down": True, "button": "left"}}])
ev([{"type": "btn", "data": {"down": False, "button": "left"}}])
PYEOF
sleep 8
echo "--- inject attempt B ---"
python3 - <<'PYEOF'
import json, socket, time
s = socket.socket(socket.AF_UNIX); s.connect("/tmp/ox-qmp")
f = s.makefile("rw"); f.readline()
def send(c):
    f.write(json.dumps(c) + "\n"); f.flush()
    return json.loads(f.readline())
send({"execute": "qmp_capabilities"})
r = send({"execute": "input-send-event", "arguments": {"events": [
    {"type": "abs", "data": {"axis": "x", "value": 30000}},
    {"type": "abs", "data": {"axis": "y", "value": 30000}}]}})
print("ev:", r)
PYEOF
sleep 6
echo "--- guest pointer evidence ---"
grep -a "pointer-move\|pointer watching\|pointer device" "$LOG" | tail -6 || echo "no pointer evidence"
pkill -f "qemu-sy""stem-aarch64" >/dev/null 2>&1 || true
