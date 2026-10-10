#!/bin/sh
# Pointer/touch gate: boot with virtio-gpu + keyboard + tablet, wait for the
# two windows (ox-status card + inputd console), then drive the absolute
# pointer via QMP input-send-event: move onto the top-right card, click
# (raises/focuses it), move onto the bottom console, click (raises that).
# Verifies pointer-move and window-raise milestones for distinct window ids
# in the serial log and saves the screendump artifact.
# usage: gfx-pointer-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S] [OUTDIR]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-420}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${4:-$PAYLOAD}"
LOG="$PAYLOAD/serial-pointer.log"
PPM="$OUT/pointer-screendump.ppm"
rm -f "$LOG" "$PPM" /tmp/ox-qmp

say() { printf '[ox-pointer] %s\n' "$*"; }
fail() { printf '[ox-pointer] FAIL: %s\n' "$*" >&2; exit 1; }
command -v qemu-system-aarch64 >/dev/null || fail "qemu missing"

(OX_GFX=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

# 1. wait for two windows (card + console)
i=0
while [ $i -lt 120 ]; do
    N=$(grep -c "name=window-new" "$LOG" 2>/dev/null || echo 0)
    [ "$N" -ge 2 ] && break
    sleep 2; i=$((i + 1))
done
N=$(grep -c "name=window-new" "$LOG" 2>/dev/null || echo 0)
[ "$N" -ge 2 ] || {
    tail -5 "$LOG"; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
    fail "expected 2 windows, saw $N"; }
say "both windows created"
sleep 2

# 2. absolute pointer choreography via QMP:
#    click top-right card (pos 1180,40), then click bottom console (600,700)
python3 - <<'PYEOF'
import json, socket, time

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
def ev(events):
    r = send({"execute": "input-send-event", "arguments": {"events": events}})
    assert "error" not in r, r
    time.sleep(0.15)
def move(x, y):
    ev([{"type": "abs", "data": {"axis": "x", "value": x}},
        {"type": "abs", "data": {"axis": "y", "value": y}}])
def click():
    ev([{"type": "btn", "data": {"down": True, "button": "left"}}])
    ev([{"type": "btn", "data": {"down": False, "button": "left"}}])
# QMP abs values are 0..0x7FFF, mapped by QEMU onto the device axis range
# screen(x,y) -> QMP abs: v = coord*32767/screen (1280x800)
move(30483, 1638); click()    # top-right card (1191, 40)
move(15359, 28671); click()   # bottom console (600, 700)
s.close()
PYEOF
sleep 3

# 3. screendump before shutdown
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
print("screendump ok")
PYEOF

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1

# 4. verify the chain in the serial log
MOVES=$(grep -c "name=pointer-move" "$LOG" || true)
[ "$MOVES" -ge 2 ] || fail "expected >=2 pointer moves, got $MOVES"
say "pointer moves: $MOVES"
RAISES=$(grep "name=window-raise" "$LOG" | sed 's/.*id=\([0-9]*\).*/\1/' | sort -u | wc -l)
[ "$RAISES" -ge 2 ] || fail "expected raises on >=2 distinct window ids, got $RAISES"
say "distinct focused windows: $RAISES"

# 5. artifact sanity + PNG
python3 - "$PPM" "$OUT/pointer-screendump.png" <<'PYEOF'
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
ratio = lit / (w * h)
print(f"[ox-pointer] framebuffer {w}x{h}, lit-pixel ratio {ratio:.4f}")
assert ratio > 0.5, "scanout dead"
import struct, zlib
def chunk(tag, payload):
    c = struct.pack(">I", len(payload)) + tag + payload
    return c + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
raw = b"".join(b"\x00" + data[y*w*3:(y+1)*w*3] for y in range(h))
png_data = (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6))
            + chunk(b"IEND", b""))
with open(png, "wb") as out:
    out.write(png_data)
print(f"[ox-pointer] wrote {png}")
PYEOF
say "ALL GREEN — pointer -> focus/raise -> compositor -> pixels proven"
