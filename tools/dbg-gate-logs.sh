#!/bin/sh
# Debug: sizes + last kernel timestamps of the failed GFX gates' logs.
for f in /tmp/ox-btg/serial-bt.log \
         /tmp/ox-dialgate/serial-dialer.log \
         /tmp/ox-smsgate/serial-sms.log \
         /tmp/ox-tilesgate/serial-tiles.log \
         /tmp/ox-camappgate/serial-camapp.log \
         /tmp/ox-wfg/serial-wifi.log; do
    if [ -f "$f" ]; then
        LAST=$(grep -a '^\[' "$f" | tail -1 | grep -o '\[[ 0-9.]*\]' | head -1)
        echo "$f size=$(wc -c < "$f") last=$LAST"
    else
        echo "$f MISSING"
    fi
done
echo "--- sweep failure lines:"
grep -a 'FAIL:' /tmp/sweep-bt-gate.log /tmp/sweep-dialer-app-gate.log /tmp/sweep-sms-app-gate.log /tmp/sweep-tiles-gate.log /tmp/sweep-grid-event-gate.log /tmp/sweep-uninstall-gate.log 2>/dev/null | cut -c1-160
