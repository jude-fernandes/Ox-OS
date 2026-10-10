#!/usr/bin/env python3
"""Add the PipeWire board row to README-PHASE1.md after the receipts row."""

p = "README-PHASE1.md"
text = open(p, encoding="utf-8", newline="").read().replace("\r\n", "\n")

anchor = "Durable payment receipts (`/data/ox/receipts.jsonl`, fsynced)"
row = "| PipeWire audio service (lean musl cross-build, s6 longrun) | DONE (gate: server native round-trip + tone through pipewire -> ALSA -> virtio-sound, wav RMS 6834; conf.d static sink + auto-port-config, no SM needed) | tools/pipewire-gate.sh ALL GREEN |"

lines = text.split("\n")
idx = None
for i, line in enumerate(lines):
    if anchor in line:
        idx = i
        break
assert idx is not None, "anchor row not found"
if "PipeWire audio service" not in text:
    lines.insert(idx + 1, row)
    open(p, "w", encoding="utf-8", newline="").write("\n".join(lines))
    print("board row added after receipts row")
else:
    print("row already present")
