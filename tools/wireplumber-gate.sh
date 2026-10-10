#!/bin/sh
# WirePlumber gate: boot the payload with virtio-sound-pci wired to QEMU's
# wav audiodev; require the full session-manager path: pipewire server up
# (pipewire-up), WirePlumber up and serving session objects
# (wireplumber-up), then a REAL client stream — pw-play with no --target
# and no manual linking — completes (wp-played), and the host wav dump is
# non-silent. This supersedes the pipewire-gate playback path: with a
# session manager present the static conf.d sink workaround is gone and
# device discovery is dynamic (monitor.alsa).
# usage: wireplumber-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-420}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-wpgate
LOG="$OUT/serial-wp.log"
WAV="$OUT/dump.wav"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-wp] %s\n' "$*"; }
fail() { printf '[ox-wp] FAIL: %s\n' "$*" >&2; exit 1; }

(OX_GFX=0 OX_VERBOSE=1 OX_QEMU_EXTRA="-audiodev driver=wav,id=oxwav,path=$WAV \
    -device virtio-sound-pci,audiodev=oxwav" \
    timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

# 1. pipewire server up
i=0
while [ $i -lt 120 ]; do
    grep -aq -e "name=pipewire-up" -e "name=pipewire-failed" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -aq "name=pipewire-up" "$LOG" || {
    tail -8 "$LOG" 2>/dev/null || true; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
    fail "no pipewire-up milestone (server did not serve a client)"; }
say "pipewire server up (native-protocol round trip ok):"
grep -a "name=pipewire-up" "$LOG" | tail -1 | sed 's/^/[ox-wp]   /'

# 2. wireplumber session manager up
j=0
while [ $j -lt 90 ]; do
    grep -aq -e "name=wireplumber-up" -e "name=wireplumber-failed" -e "name=wireplumber-no-server" "$LOG" 2>/dev/null && break
    sleep 2; j=$((j + 1))
done
grep -aq "name=wireplumber-up" "$LOG" || {
    # let any in-run debug dump finish before tearing down
    sleep 15
    tail -30 "$LOG" 2>/dev/null || true; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
    fail "no wireplumber-up milestone (session manager did not come up)"; }
say "wireplumber up (session objects visible to wpctl):"
grep -a "name=wireplumber-up" "$LOG" | tail -1 | sed 's/^/[ox-wp]   /'

# 3. real client stream playback
k=0
while [ $k -lt 60 ]; do
    grep -aq -e "name=wp-played" -e "name=wp-play-failed" "$LOG" 2>/dev/null && break
    sleep 2; k=$((k + 1))
done
grep -aq "name=wp-played" "$LOG" || {
    sleep 15
    tail -40 "$LOG" 2>/dev/null || true; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
    fail "no wp-played milestone (pw-play client stream did not complete)"; }
say "client stream linked and completed (pw-play, no manual linking):"
grep -a "name=wp-played" "$LOG" | tail -1 | sed 's/^/[ox-wp]   /'

# 4. stop QEMU (flushes the wav) and verify the dump
pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 2
python3 - "$WAV" <<'PYEOF'
import sys, wave, audioop
path = sys.argv[1]
w = wave.open(path, "r")
n = w.getnframes()
data = w.readframes(n)
rms = audioop.rms(data, 2)
print(f"[ox-wp] captured wav: {n} frames @ {w.getframerate()} Hz, RMS {rms}")
assert n > 40000, "too few frames captured"
assert rms > 300, "captured audio is silent"
print("[ox-wp] wav dump non-silent — audio reached the host")
PYEOF
say "ALL GREEN — pipewire up + wireplumber up + client stream through session manager"
echo "WIREPLUMBER GATE ALL GREEN"
