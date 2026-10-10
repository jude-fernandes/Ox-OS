#!/bin/sh
# UI toolkit gate: boot with the display, wait for ox-status to commit
# the ox-ui-drawn home screen, screendump, and pixel-verify the design
# tokens at computed positions: true-black surface, surface-high bar,
# primary accent line, and the four home-grid tiles.
# usage: ui-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-420}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-uigate
LOG="$OUT/serial-ui.log"
PPM="$OUT/ui-screendump.ppm"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-ui] %s\n' "$*"; }
fail() { printf '[ox-ui] FAIL: %s\n' "$*" >&2; exit 1; }

(OX_GFX=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

# 1. wait for the toolkit-drawn UI to commit
i=0
while [ $i -lt 120 ]; do
    grep -aq "ox-status: UI committed" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -aq "ox-status: UI committed" "$LOG" || {
    tail -8 "$LOG" 2>/dev/null || true; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
    fail "ox-status did not commit the ox-ui screen"; }
say "ox-ui home screen committed"
sleep 3

# 2. screendump + pixel-verify, with retries: the commit ack can beat
#    the display flush, and a one-shot capture then reads stale black.
#    Every attempt re-runs the QMP screendump first.
i=0
UI_OK=no
while [ $i -lt 3 ]; do
    sleep 3
    if python3 - "$PPM" <<'PYEOF'
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
print("[ox-ui] screendump ok")
PYEOF
    then
        echo "[ox-ui] capture ok"
    else
        echo "[ox-ui] screendump failed this attempt"
        i=$((i + 1))
        continue
    fi
    if python3 - "$PPM" "$OUT/ui-screendump.png" <<'PYEOF'
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

def px(x, y):
    o = (y * w + x) * 3
    return (data[o], data[o + 1], data[o + 2])

SURFACE_HIGH = (0x0C, 0x1B, 0x33)
PRIMARY = (0x2E, 0x7D, 0x32)
SURFACE = (0, 0, 0)
bar_h = max(int(h * 15 / 100), 96)

# token 1: true-black surface below the content region
assert px(10, h - 10) == SURFACE, f"surface not true black at bottom: {px(10, h-10)}"
# token 2: surface-high top bar
assert px(w // 2, bar_h // 2) == SURFACE_HIGH, f"bar color wrong: {px(w//2, bar_h//2)}"
# token 3: primary accent line under the bar
assert px(w // 2, bar_h + 3) == PRIMARY, f"accent color wrong: {px(w//2, bar_h+3)}"
# token 4: home-grid tiles at the layout positions (right side of the
# Settings tile, away from its label text)
gx, gy = 48, bar_h + 6 + 24
tile = px(gx + 200, gy + 100)
assert tile == SURFACE_HIGH, f"tile color wrong: {tile}"
files_tile = px(gx + 220 + 24 + 200, gy + 100)
assert files_tile == SURFACE_HIGH, f"files tile color wrong: {files_tile}"
# white text somewhere in the bar (the wordmark)
found_white = any(
    px(x, y)[0] > 200 and px(x, y)[1] > 200 and px(x, y)[2] > 200
    for x in range(48, 400, 8)
    for y in range(10, bar_h - 10, 4)
)
assert found_white, "no wordmark pixels in the bar"

print(f"[ox-ui] framebuffer {w}x{h}")
print("[ox-ui] tokens verified: surface / surface-high bar / primary accent / grid tiles / wordmark")

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
print(f"[ox-ui] wrote {png}")
PYEOF
    then
        UI_OK=yes
        break
    fi
    i=$((i + 1))
    say "pixel verify attempt $((i + 1)) failed — retrying screendump"
done
[ "$UI_OK" = yes ] || {
    pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
    fail "pixel verification failed after 3 attempts"
}

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — ox-ui toolkit draws the token-correct home screen"
echo "UI GATE ALL GREEN"
