#!/usr/bin/env python3
"""Replace the OPEN ITEM section of the pipewire handoff with the latest
session evidence (2026-09-04 evening iteration round)."""
import io

p = "docs/process/reports/2026-09-03-pipewire-handoff.md"
text = io.open(p, encoding="utf-8", newline="").read().replace("\r\n", "\n")

start = text.index("### OPEN ITEM")
end = text.index("Once `pipewire-played` fires")

new_section = """### OPEN ITEM (next session) - pw-play stream completion
Current state (rootfs.nix 10-ox-alsa.conf + pipewire run script -
STABLE: server up, no alsa errors, sink node exists, pipewire-sink
milestone green):
    context.objects = [ { factory = adapter
        args = { factory.name = "api.alsa.pcm.sink"
                 node.name = "ox-speaker"
                 media.class = "Audio/Sink"
                 api.alsa.card = 0
                 node.driver = true } } ]
plus in run script: ALSA_CONFIG_DIR=<alsa-lib store>/share/alsa (musl
alsa-lib honors it - verified via strings), /dev/snd/pcmC0D0p wait
before start, LD_LIBRARY_PATH, RUNTIME_DIRs.

Remaining symptom: pw-play [--target ox-speaker] /usr/share/ox/tone.wav
connects and TIMES OUT after 20 s with no output (stream never reaches
running). The adapter node likely lacks something a session manager
would set (port state / format offering / driver wiring). The alsa-lib
"Cannot get card index" flake is fixed by ALSA_CONFIG_DIR + device wait
(both boots since: clean).

Next steps (cheapest first):
a. Interactive serial probe (tools/pw-console-probe.sh) - commands DO
   execute in-guest, but root login still asks a password (passwd entry
   root::0:0... added to rootfs.nix; busybox login may need an extra
   newline for the Password prompt, and typed chars get dropped when
   boot output overlaps - echo a marker after each command and re-type
   on mismatch). Run pw-play with PIPEWIRE_DEBUG=3 BY HAND and read the
   stream state directly.
b. pw-cli ls Port in-guest: confirm ox-speaker has input ports (if none,
   the adapter never negotiated - try audio.position = [ FL FR ] or
   explicit audio.format = S16_LE audio.rate = 48000 audio.channels = 1).
c. If ports exist but stream stalls: try pw-cat --playback instead of
   pw-play.

"""

text = text[:start] + new_section + text[end:]
io.open(p, "w", encoding="utf-8", newline="").write(text)
print("handoff OPEN ITEM updated")
