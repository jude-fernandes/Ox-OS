#!/usr/bin/env python3
"""Final update: pw-play mystery SOLVED — missing session manager link.
Amend the handoff and report with the honest milestone boundary."""

p = "docs/process/reports/2026-09-03-pipewire-handoff.md"
text = open(p, encoding="utf-8", newline="").read().replace("\r\n", "\n")

section = """

### RESOLVED DIAGNOSIS (2026-09-04, final): stream linking needs a session manager

Full evidence chain from the wake-locked in-guest debug dump:
- auto-port-config WORKS: ox-speaker now has its input port
  (port.name=playback_1, direction=in, group=stream.0).
- pw-play connects to the server, creates its stream node pw-play-0,
  which reaches `creating -> suspended` — and stays there until the
  8s timeout destroys it (pw_impl_node_destroy in the log).
- Root cause: pipewire does NOT auto-link streams to sinks. Link
  creation is the session manager's job (WirePlumber). Without one:
  stream suspended forever, pw-play rc=1 (killed), silent because
  nothing failed — the graph simply has no link.

Options for the next session (product decision, not a bug):
1. WirePlumber cross-build (the real SM; lua + deps — heavier, needs
   closure+integration work like pipewire got; the RIGHT long-term
   choice for hardware targets with dynamic devices).
2. Server-side static link: load module-link-factory in the server
   config and create a link object (link.output.node=30,
   link.input.node=<pw-play stream id>) — but the stream id changes
   every run; needs a wrapper script that waits for the stream node id
   then creates the link. Feasible for the GATE (fixed topologies).
3. Accept the server-runtime milestone as the Phase-2 deliverable and
   defer dynamic playback to the hardware phase (WirePlumber there).

The gate stays as-is: it goes ALL GREEN the moment pipewire-played
fires through whichever path (2) provides.
"""

if "RESOLVED DIAGNOSIS" not in text:
    text = text.rstrip() + "\n" + section
    open(p, "w", encoding="utf-8", newline="").write(text)
    print("handoff updated")
else:
    print("already present")
