#!/bin/sh
# Throwaway analysis: summarize the DRM debug output of a diag boot.
L="${1:-/tmp/ox-com/payload/serial-trace.log}"
echo "lines: $(wc -l <"$L")"
echo "flip:  $(grep -c compositor-rendered "$L")"
echo "--- drm function histogram (last 4000 lines) ---"
tail -4000 "$L" | grep -o '\[drm:[a-z_0-9]*\]' | sort | uniq -c | sort -rn | head -25
echo "--- virtio/set_scanout/xfer/flush lines ---"
grep -iE 'set_scanout|xfer|flush|nofb|virtio_gpu' "$L" | grep '\[drm' | tail -15
