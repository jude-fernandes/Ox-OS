#!/bin/sh
. "$(dirname "$0")/gate-lib.sh"   # chunk-54 guest-time waits
# Camera gate (Phase 4): the REAL V4L2 stack with vivid as the
# virtual sensor. The gate requires, in order: ox-camerad serving ->
# /dev/video0 exists (modules loaded) -> honest DENY refused -> FAKE
# produces a clearly-synthetic frame -> GRANT captures a REAL frame
# whose 8-bar color strip is pinned (colors=8) -> lifecycle green.
# usage: camera-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-900}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-cameragate
LOG="$OUT/serial-camera.log"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-cam] %s\n' "$*"; }
fail() { printf '[ox-cam] FAIL: %s\n' "$*" >&2; exit 1; }

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

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1

(OX_KERNEL_EXTRA=" ox.pm_drill=off" OX_GFX=0 OX_VERBOSE=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

# 1. service up, sensor present
wait_guest "name=camerad-ready" 360000 1800 "ox-camerad never started"
say "ox-camerad serving"
wait_guest "name=camera-vivid-ok" 540000 1800 "vivid never produced /dev/video0 (kernel lacks V4L2/vivid or module load failed)"
say "virtual sensor up: /dev/video0 (vivid)"
grep -a "name=camera-vivid-ok" "$LOG" | tail -1 | sed 's/^/[ox-cam]   /'

# 2. honest-permission lifecycle
wait_guest "name=camera-deny-refused" 180000 1800 "camera.read deny was not refused"
say "deny refused"
wait_guest "name=camera-fake-synthetic" 180000 1800 "fake mode did not produce a clearly-synthetic frame"
say "fake served a synthetic frame"
wait_guest "name=camera-real-captured colors=8" 360000 1800 "grant did not capture a REAL frame with vivid's 8-bar color strip"
say "grant captured a REAL frame (vivid color strip, colors=8)"
grep -a "name=camera-capture " "$LOG" | tail -1 | sed 's/^/[ox-cam]   /'
grep -a "DBG-CAM-GRANT" "$LOG" | tail -1 | cut -c1-220 | sed 's/^/[ox-cam]   /'

wait_guest "name=camera-test-ok" 180000 1800 "selftest did not complete clean"
say "selftest completed clean"

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — camera: V4L2 read() capture from vivid, permstored deny/fake/grant, real frame pinned by colorbar analysis"
echo "CAMERA GATE ALL GREEN"
