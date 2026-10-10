# Chunk 67 — boot completeness: every daemon self-reports, the boot gets a health gate

Date: 2026-10-04
Status: CLOSED — BOOT-HEALTH GATE ALL GREEN (first run), 19/19 daemons serving, 0 deaths

## The gap this closes

The phase-4 exit walks kept hitting a flake class whose evidence was
unusable: a boot where a core daemon simply never appeared (run-4b's
camera-app boot had no powerd at all; run-5's bt died with a truncated
log). After such a boot, the gate fails on an ABSENT pattern — the
differential diagnosis is "daemon never started" vs "daemon died
pre-journal" vs "serial line lost", and with only oxcom carrying an
exit-code journal (chunk 63), most boots couldn't answer.

## What landed

1. **Fleet-wide exit-code journals** — 23 daemon run files now carry the
   chunk-63 pattern (`NAME: exited rc=<N>` on the kernel ring, s6
   restarts as usual): camerad contactsd gnssd hostapd intentd locationd
   lockd messagesd netd nfcd notifd ox-shell oxmodemd oxwifid
   permstored resourced thermald usbd wpa_supplicant ox-status inputd
   oxpaymentsd powerd. A death before the first milestone can no longer
   be silent. (Done via `tools/chunk67-exit-journals.py` for the 19
   direct-exec files + manual edits for the four if-block shapes.)
2. **boot-health-selftest** (s6 longrun, 58th service): at boot+settle it
   walks the socket manifest — 19 core daemons' `/run/ox/sockets/*.sock`
   — and journals `boot-health missing=<csv|none>` with a NAMED
   `boot-daemon-down daemon=<name>` line for every gap.
3. **boot-health gate**: fresh payload, waits for the manifest walk,
   refuses ANY missing daemon by name, reports the boot's daemon-death
   count from the fleet journals, and sanity-checks the client layer
   (shell-locked + compositor stage serving). This gate is also the
   regression proof for the 23 run-file rewrites — any broken run file
   would name itself.

## Verification

- workspace-test ALL GREEN; payload builds with the 58th service
  (s6 integrity 58=58 on the gate's own guard when the sweep next runs)
- **BOOT-HEALTH GATE ALL GREEN, first run**: `boot-health missing=none`,
  daemon deaths this boot: 0, shell locked, compositor serving
- Honest note: the gate's RED path (a named missing daemon) is asserted
  by construction — no daemon was broken on demand to exercise it; the
  first real boot that loses a daemon will exercise it for free.

## Watch items / next leads

- AP wedge (hostapd refusing its own client under VM-long-uptime, run-5
  wifi): still open; next sighting should be caught by the wifi gate's
  own evidence + the fleet journals.
- Kernel-side virtio-gpu modeset wedge across suspend (chunk-64
  documentation): needs a kernel fix, out of userspace scope.
