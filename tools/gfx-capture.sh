#!/bin/sh
# Graphics bring-up gate: boot with virtio-gpu, wait for userspace-ready,
# capture a QEMU screendump of the framebuffer console, assert real content.
# usage: gfx-capture.sh PAYLOAD_DIR KERNEL_IMAGE [TIMEOUT_S] [OUTDIR] [MINRATIO]
# MINRATIO: lit-pixel floor (default 0.001 = kernel console text; use ~0.9
# to prove a full-screen compositor surface owns the scanout).
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-420}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${4:-$PAYLOAD}"
MINRATIO="${5:-0.001}"
LOG="$PAYLOAD/serial-gfx.log"
rm -f "$LOG" /tmp/ox-qmp

say() { printf '[ox-gfx] %s\n' "$*"; }
fail() { printf '[ox-gfx] FAIL: %s\n' "$*" >&2; exit 1; }

command -v qemu-system-aarch64 >/dev/null || fail "qemu missing"

(OX_GFX=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

i=0
while [ $i -lt 240 ]; do
    grep -q "name=userspace-ready" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -q "name=userspace-ready" "$LOG" || {
    tail -5 "$LOG"; pkill -f qemu-system-aarch64 || true; fail "no boot"; }

# Optional gate on a later milestone (e.g. OX_WAIT_MILESTONE=compositor-rendered)
if [ -n "${OX_WAIT_MILESTONE:-}" ]; then
    i=0
    while [ $i -lt 60 ]; do
        grep -q "name=$OX_WAIT_MILESTONE" "$LOG" 2>/dev/null && break
        sleep 1; i=$((i + 1))
    done
    grep -q "name=$OX_WAIT_MILESTONE" "$LOG" || {
        tail -5 "$LOG"; pkill -f qemu-system-aarch64 || true
        fail "milestone $OX_WAIT_MILESTONE not reached"; }
    say "milestone reached: $OX_WAIT_MILESTONE"
fi

sleep 3   # let fbcon paint

PPM="$OUT/gfx-screendump.ppm"
rm -f "$PPM"
python3 - "$PPM" <<'PYEOF'
import json, socket, sys

def qmp(cmd):
    s = socket.socket(socket.AF_UNIX)
    s.connect("/tmp/ox-qmp")
    f = s.makefile("rw")
    f.readline()                       # greeting
    def send(c):
        f.write(json.dumps(c) + "\n"); f.flush()
        return json.loads(f.readline())
    send({"execute": "qmp_capabilities"})
    r = send(cmd)
    s.close()
    return r

r = qmp({"execute": "screendump",
         "arguments": {"filename": sys.argv[1]}})
if "error" in r:
    sys.exit(f"screendump failed: {r}")
print("screendump ok")
PYEOF
pkill -f qemu-system-aarch64 || true

python3 - "$PPM" "$MINRATIO" <<'PYEOF'
import sys

path = sys.argv[1]
min_ratio = float(sys.argv[2])
with open(path, "rb") as f:
    magic = f.read(3).strip()
    assert magic == b"P6", magic
    dims = []
    while len(dims) < 2:
        line = f.readline()
        if line.startswith(b"#"):
            continue
        dims += [int(x) for x in line.split()]
    w, h = dims[:2]
    maxv = int(f.readline())
    data = f.read()
lit = sum(1 for i in range(0, len(data), 3)
          if data[i] or data[i+1] or data[i+2])
ratio = lit / (w * h)
print(f"[ox-gfx] framebuffer {w}x{h}, lit-pixel ratio {ratio:.4f}")
assert ratio > min_ratio, "screen content below expected floor"
print("[ox-gfx] PIXELS OK")
PYEOF

grep -m1 "virtio_gpu" "$LOG" >/dev/null &&
    say "drm driver present: $(grep -m1 'virtio_gpu.*\[' "$LOG" | cut -c1-80)" ||
    say "note: driver line not matched (check log)"
say "ALL GREEN — artifact: $PPM"
