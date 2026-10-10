#!/bin/sh
LOG=/tmp/ox-audio/serial-audio.log
[ -f "$LOG" ] || { echo "gate log missing"; exit 0; }
echo "== audio-related lines =="
grep -an "audio\|snd\|dsp\|OXMILESTONE name=s6-services-up\|s6-rc" "$LOG" | head -25
echo "== snd-virtio bind? =="
grep -an "virtio_snd\|snd-virtio\|sound" "$LOG" | head -10
echo "== last 15 lines =="
tail -15 "$LOG"
