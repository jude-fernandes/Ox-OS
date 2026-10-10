#!/usr/bin/env python3
# Remove the static conf.d sink/tone block from rootfs.nix: WirePlumber
# owns device discovery now. Replaces lines from the "No session manager"
# comment through the OXA heredoc terminator with a short explanation.
import io, sys

path = "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/system/rootfs.nix"
src = io.open(path, "r", encoding="utf-8").read()
lines = src.splitlines(keepends=True)

start = end = None
for i, ln in enumerate(lines):
    if "No session manager (WirePlumber) in the guest" in ln:
        start = i
    if start is not None and ln.rstrip("\r\n") == "OXA":
        end = i
        break
if start is None or end is None:
    sys.exit("anchors not found: start=%s end=%s" % (start, end))

indent = "    "
replacement = (
    "# No static ALSA sink in pipewire.conf.d: WirePlumber (below) owns\n"
    "# device discovery and node creation now (monitor.alsa ->\n"
    "# api.alsa.enum.udev, whose libudev dependency survived the lean\n"
    "# filter -- see tools/wp-inspect4.sh evidence). A static node would\n"
    "# race the monitor for the same PCM device.\n"
)
lines[start:end + 1] = [replacement]
io.open(path, "w", encoding="utf-8", newline="").write("".join(lines))
print("replaced lines %d..%d" % (start + 1, end + 1))
