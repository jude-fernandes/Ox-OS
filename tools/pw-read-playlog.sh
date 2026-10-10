#!/bin/sh
# Read the tail of the pw-play debug log from the last gate run.
LOG=/tmp/ox-pwgate/serial-pw.log
grep -an 'DBG-PLAYLOG\|DBG-PLAY-RC' "$LOG" | head -4
START="$(grep -an 'DBG-PLAYLOG' "$LOG" | cut -d: -f1 | head -1)"
END="$(grep -an 'DBG-PLAY-RC' "$LOG" | cut -d: -f1 | head -1)"
if [ -n "$START" ] && [ -n "$END" ]; then
    sed -n "${START},${END}p" "$LOG" | grep -av 'login\|powerd\|ox-status\|suspend\|Freez\|OOM\|printk\|Restart\|crng\|virtio_blk\|PM:\|^[[:space:]]*$' | tail -28
fi
