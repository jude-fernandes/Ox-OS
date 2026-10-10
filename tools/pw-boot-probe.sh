#!/bin/sh
# Boot the payload once and collect pipewire-related console output (v2:
# robust path extraction — the nix output may contain progress lines).
set -eu
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
P="$(sed -n 1p /tmp/nixout.txt)"
K="$(sed -n 2p /tmp/nixout.txt)/Image"
echo "payload: $P"
echo "kernel:  $K"
[ -d "$P" ] || { echo "bad payload path"; exit 1; }
rm -rf /tmp/ox-pw-payload && mkdir -p /tmp/ox-pw-payload
cp -r "$P"/. /tmp/ox-pw-payload/
OUT=/tmp/ox-pw
LOG="$OUT/serial.log"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon
(OX_GFX=1 timeout 180 bash targets/qemu-virt-aarch64/run-qemu.sh \
    /tmp/ox-pw-payload "$K" "$LOG" >/dev/null 2>&1 &)
i=0
while [ $i -lt 60 ]; do
    grep -q "audio-played\|pipewire" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
sleep 20
pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
echo "== pipewire / audio console lines =="
grep -a 'pipewire\|pw-cli\|audio\|snd\|ALSA' "$LOG" | head -25
echo "== userspace reached =="
grep -ac 'basefs-ready' "$LOG" || true
