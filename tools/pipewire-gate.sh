#!/bin/sh
# PipeWire gate: boot the payload with virtio-sound-pci wired to QEMU's
# wav audiodev; require the pipewire service to come up AND complete a
# full playback (pw-play tone -> pipewire -> ALSA -> virtio-sound -> host
# wav dump). Verifies the dump the same way audio-gate does: RIFF, frames,
# non-silent RMS. Requires pipewire-up AND pipewire-played milestones.
# usage: pipewire-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-420}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-pwgate
LOG="$OUT/serial-pw.log"
WAV="$OUT/dump.wav"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-pw] %s\n' "$*"; }
fail() { printf '[ox-pw] FAIL: %s\n' "$*" >&2; exit 1; }

(OX_GFX=0 OX_VERBOSE=1 OX_QEMU_EXTRA="-audiodev driver=wav,id=oxwav,path=$WAV \
    -device virtio-sound-pci,audiodev=oxwav" \
    timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

# 1. wait for the service verdict (up or failed)
i=0
while [ $i -lt 120 ]; do
    grep -q "name=pipewire-up\|name=pipewire-failed" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -q "name=pipewire-up" "$LOG" || {
    tail -8 "$LOG" 2>/dev/null || true; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
    fail "no pipewire-up milestone (server did not serve a client)"; }
say "pipewire server up (native-protocol round trip ok):"
grep -a "name=pipewire-up" "$LOG" | tail -1 | sed 's/^/[ox-pw]   /'

# 2. wait for the playback verdict (played / timeout / sink-failed)
j=0
while [ $j -lt 60 ]; do
    grep -aq -e "name=pipewire-played" -e "name=pipewire-play-timeout" -e "name=pipewire-sink-failed" "$LOG" 2>/dev/null && break
    sleep 2; j=$((j + 1))
done
grep -aq "name=pipewire-played" "$LOG" || {
    # let the in-run-script debug dump finish before tearing down
    sleep 20
    tail -10 "$LOG" 2>/dev/null || true; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
    fail "no pipewire-played milestone (pw-play through ALSA failed)"; }
say "playback through pipewire -> ALSA -> virtio-sound completed:"
grep -a "name=pipewire-played" "$LOG" | tail -1 | sed 's/^/[ox-pw]   /'

# 3. stop QEMU (flushes the wav) and verify the dump
pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 2
python3 - "$WAV" <<'PYEOF'
import sys, wave, audioop
path = sys.argv[1]
w = wave.open(path, "r")
n = w.getnframes()
data = w.readframes(n)
rms = audioop.rms(data, 2)
print(f"[ox-pw] captured wav: {n} frames @ {w.getframerate()} Hz, RMS {rms}")
assert n > 40000, "too few frames captured"
assert rms > 300, "captured audio is silent"
print("[ox-pw] wav dump non-silent — audio reached the host")
PYEOF
say "ALL GREEN — pipewire service up + tone through pipewire -> ALSA -> virtio-sound"
echo "PIPEWIRE GATE ALL GREEN"
