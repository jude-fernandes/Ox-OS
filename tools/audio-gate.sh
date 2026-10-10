#!/bin/sh
# Audio gate: boot the payload with a virtio-sound-pci device wired to
# QEMU's `wav` audiodev, wait for the guest's audio-selftest oneshot to
# play a 1 s 440 Hz tone, stop QEMU (flushes the wav), then verify the
# dump: valid RIFF, enough frames, non-silent RMS.
# usage: audio-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-420}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-audio
LOG="$OUT/serial-audio.log"
WAV="$OUT/dump.wav"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-audio] %s\n' "$*"; }
fail() { printf '[ox-audio] FAIL: %s\n' "$*" >&2; exit 1; }

(OX_GFX=0 OX_VERBOSE=1 OX_QEMU_EXTRA="-audiodev driver=wav,id=oxwav,path=$WAV \
    -device virtio-sound-pci,audiodev=oxwav" \
    timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

# 1. wait for the guest playback milestone
i=0
while [ $i -lt 120 ]; do
    grep -q "name=audio-played" "$LOG" 2>/dev/null && break
    grep -qiE "audio-selftest.*(failed|no player)" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -q "name=audio-played" "$LOG" || {
    tail -8 "$LOG" || true; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
    fail "no audio-played milestone (player skipped, failed, or /dev/dsp missing)"; }
say "guest played the tone:"
grep "name=audio-played" "$LOG" | tail -1 | sed 's/^/[ox-audio]   /'
sleep 2

# 2. stop QEMU gracefully so the wav backend flushes
pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 3
[ -f "$WAV" ] || fail "wav dump missing ($WAV)"

# 3. verify the dump
python3 - "$WAV" <<'PYEOF'
import sys, wave, array

path = sys.argv[1]
w = wave.open(path, "rb")
nch, width, rate, frames = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
print(f"[ox-audio] wav: {nch}ch {width*8}bit {rate}Hz {frames} frames "
      f"({frames / rate:.2f}s)")
assert width == 2, f"expected 16-bit, got {width*8}"
assert frames >= rate // 2, f"too short: {frames} frames ({frames/rate:.2f}s)"
data = array.array("h")
data.frombytes(w.readframes(frames))
mono = data[::nch]
rms = (sum(x * x for x in mono) / len(mono)) ** 0.5
peak = max(abs(x) for x in mono)
print(f"[ox-audio] rms={rms:.0f} peak={peak}")
assert rms > 300, f"audio is (near-)silent: rms={rms:.0f}"
print("[ox-audio] wav dump verified: non-silent, expected duration")
PYEOF

say "ALL GREEN — device(virtio-sound) -> kernel(snd-virtio+OSS) -> player -> host wav proven"
