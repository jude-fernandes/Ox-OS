#!/bin/sh
# Debug: pm-suspend epoch values across the day's gate logs.
for f in /tmp/ox-wfg/serial-wifi.log \
         /tmp/ox-btg/serial-bt.log \
         /tmp/ox-usbgate/serial-usb.log \
         /tmp/ox-cameragate/serial-camera.log \
         /tmp/ox-camappgate/serial-camapp.log \
         /tmp/ox-dialgate/serial-dialer.log \
         /tmp/ox-nfcgate/serial-nfc.log; do
    if [ -f "$f" ]; then
        E=$(grep -a 'pm-suspend-request' "$f" | tail -1 | grep -o 'epoch=[0-9]*')
        echo "$(basename "$(dirname "$f")"): ${E:-no-suspend-found}"
    fi
done
