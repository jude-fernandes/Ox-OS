#!/usr/bin/env python3
"""Generate the 1s 440 Hz test tone used by the pipewire audio gate."""
import math, struct, wave

w = wave.open("system/tone.wav", "w")
w.setnchannels(1)
w.setsampwidth(2)
w.setframerate(48000)
frames = b"".join(
    struct.pack("<h", int(12000 * math.sin(2 * math.pi * 440 * n / 48000)))
    for n in range(48000)
)
w.writeframes(frames)
w.close()
print("system/tone.wav written")
