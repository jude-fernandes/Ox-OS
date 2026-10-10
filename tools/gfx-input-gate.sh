#!/bin/sh
# Input-stack gate: boot with virtio-gpu + virtio-keyboard, wait for the
# inputd console window, type "hello world oxos<ret>" through the QEMU
# monitor's sendkey (flows into the guest exactly like physical keystrokes),
# screendump, then verify the full chain in the serial log:
# inputd key lines -> oxcom window-commit milestones.
# usage: gfx-input-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S] [OUTDIR]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-420}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${4:-$PAYLOAD}"
LOG="$PAYLOAD/serial-input.log"
PPM="$OUT/input-screendump.ppm"
rm -f "$LOG" "$PPM" /tmp/ox-qmp

say() { printf '[ox-input] %s\n' "$*"; }
fail() { printf '[ox-input] FAIL: %s\n' "$*" >&2; exit 1; }
command -v qemu-system-aarch64 >/dev/null || fail "qemu missing"

(OX_GFX=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

# 1. wait for the inputd console window to exist
i=0
while [ $i -lt 120 ]; do
    grep -q "name=window-new" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -q "name=window-new" "$LOG" || {
    tail -5 "$LOG"; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
    fail "no console window"; }
say "console window created"
sleep 2

# 2. type via the QEMU human monitor
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
def sendkey(k):
    s.send(f"sendkey {k}\n".encode())
    time.sleep(0.06)
    drain()
for k in ("h e l l o".split() + ["spc"] + "w o r l d".split() + ["spc"]
          + "o x o s".split() + ["ret"]):
    sendkey(k)
drain()
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
grep -q "inputd: key 'h'" "$LOG" || fail "no key events reached inputd"
say "keys reached inputd"
grep -q 'line committed: "hello world oxos"' "$LOG" || fail "typed line wrong"
say "line committed: hello world oxos"
COMMITS=$(grep -c "name=window-commit" "$LOG" || true)
[ "$COMMITS" -ge 5 ] || fail "expected >=5 window commits, got $COMMITS"
say "window-commit milestones: $COMMITS"

# 5. artifact sanity: screen alive and saved as PNG
python3 - "$PPM" "$OUT/input-screendump.png" <<'PYEOF'
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
print(f"[ox-input] framebuffer {w}x{h}, lit-pixel ratio {ratio:.4f}")
assert ratio > 0.5, "scanout dead"
# convert P6 -> PNG via zlib (no external deps)
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
print(f"[ox-input] wrote {png}")
PYEOF
say "ALL GREEN — input -> IPC -> compositor -> pixels proven"
