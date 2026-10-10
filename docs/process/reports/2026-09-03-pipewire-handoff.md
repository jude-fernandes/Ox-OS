# PipeWire milestone — HANDOFF (updated 2026-09-04, end of session)

## STATUS: SUPERSEDED — audio stack complete via WirePlumber (see below)

The open item below (pw-play / session manager) is CLOSED. Final state
lives in `2026-09-04-wireplumber.md`: WirePlumber 0.5.8 + eudev 3.2.14
are in the guest, dynamic discovery works, and `tools/wireplumber-gate.sh`
is ALL GREEN (pw-play with no flags → host wav RMS 3089). The static
conf.d sink described below was REMOVED from rootfs.nix; the
`pipewire-played` milestone no longer exists (superseded by `wp-played`).
Resume commands: `tools/wp-gate-run.sh` (build both attrs → clone →
wireplumber gate). Next milestones: modem scoping (biggest "phone" gap),
or LUKS R-23 retest on hardware.

---

## (HISTORICAL — the session that put the server on Ox)

### STATUS: PipeWire server RUNS ON OX (gate-verified); playback path OPEN

### Green and reproducible (3 boots)
- `OXMILESTONE name=pipewire-up` — the s6-supervised pipewire service starts
  and **serves a native-protocol client round trip** (`pw-cli info 0` ok).
- The dynamic musl guest-execution pattern works end to end: 55-path nix
  closure copied store-preserving into the rootfs; PT_INTERP =
  `/nix/store/7723bq3…/lib/ld-musl-aarch64.so.1` (verified present), all
  DT_NEEDED resolve via baked RUNPATH. `pw-cli --version` prints
  `Compiled with libpipewire 1.2.7` in-guest.
- Gate artifact: `tools/pipewire-gate.sh` (full gate = pipewire-up +
  pipewire-played + wav RMS). Currently NOT green (see open item).
- Chunked proof for the record: flake `.#pipewire-lean` reproduces the
  same store path (`ff6wlvfa…`, nixpkgs pinned to rev 50ab7937 in
  flake.nix + flake.lock updated).

### Integration knowledge (bake into future dynamic guests)
- dlopen'd plugins are NOT in the nix runtime closure → rootfs.nix copies
  `lib/pipewire-0.3`, `lib/spa-0.2`, `share` wholesale after the closure
  loop (chmod -R u+w first — closure copies land read-only).
- alsa-ucm-conf must be EXCLUDED from the closure copy: its
  "Librem 5.conf" (space in filename) breaks the payload squashfs sort
  file, and UCM is per-device data the QEMU card doesn't need.
- pipewire needs env: PIPEWIRE_RUNTIME_DIR/XDG_RUNTIME_DIR=/run/ox/pipewire
  and LD_LIBRARY_PATH widened to the module+SPA dirs (musl has no
  ld.so.conf); otherwise protocol-native fails with ENOENT.
- mod.portal errors "Failed to connect to session bus" — expected (no dbus
  in guest), non-fatal.

### OPEN ITEM (next session) - pw-play stream completion
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

Once `pipewire-played` fires: gate ALL GREEN (verifies host-side wav:
>40000 frames, RMS>300). Then Chunk E (report + board row, ~24.5%).

### Also this session
- nixpkgs pinned by rev (branch had moved mid-build before: pipewire
  1.2.7→1.6.8 graph flip). flake.lock updated; payload/kernel rebuild
  verified against the pinned tree.
- Reusable runners: `tools/pw-gate-run.sh` (build+clone+gate — no inline
  shell vars), `tools/pw-boot-probe.sh` (needs /tmp/nixout.txt with the
  two build lines: build both attrs, never just one), `tools/pw-closure.sh`.
- OSS audio-selftest currently logs "/dev/dsp unavailable" in boots WITHOUT
  the sound device attached — expected: only gates add
  `-device virtio-sound-pci`. With the device attached (this gate) the
  card is detected and OSS playback works (audio-played, frames=48000).

### Overall honest progress
~23% → PipeWire playback green will make ~24.5%. Charter rules unchanged:
gate-verified or it doesn't count; no inline $vars through wsl bash -c;
R-23 LUKS stays parked for real hardware
(reports/2026-09-01-luks-data-volume.md).


### pw-play stream completion - findings & plan (2026-09-04, session end)

Established:
- Server + ox-speaker adapter node are STABLE (pipewire-up + sink node in
  every boot; no alsa errors). Run script carries ALSA_CONFIG_DIR,
  pcmC0D0p wait, LD_LIBRARY_PATH, RUNTIME_DIRs, wake-locked debug dump.
- pw-play exits INSTANTLY rc=1 with EMPTY stderr even under
  PIPEWIRE_DEBUG=3 (log file 0 lines). client.conf now present in
  /etc/pipewire - did not change it.
- `pw-cli ls Port` is EMPTY: the adapter node has NO ports. A stream has
  nothing to link to - likely the real reason pw-play fails.
- The gate verdict grep was fixed (a sed-generated literal-pipe pattern
  made the gate blind to play-timeout/sink-failed for several runs).
- node.driver = true, audio.format/rate/channels props do not create
  ports by themselves.

Next session plan (in order):
1. READ the source (pipewire 1.2.7; re-clone: git clone --depth 1 -b
   1.2.7 https://gitlab.freedesktop.org/pipewire/pipewire /tmp/pwsrc):
   - src/modules/module-adapter.c: create_object + adapter.c find_format
     - under what conditions does the adapter create ports at load time?
   - Compare with pipewire's own static-config examples (grep
     context.objects in src/daemon/*.conf.in and docs).
   - Consider `adapt.follower.spa-node` wrapper route vs factory.name.
2. In-guest evidence via the run-script dump (works, wake-locked):
   `pw-cli info <node-id>` for ox-speaker (state, params) - extend the
   dump to include it.
3. Likely fixes to try: `api.alsa.path = "hw:0,0"` retry NOW that
   ALSA_CONFIG_DIR is set (the old failure predates it), or
   `device.profile = "default"`, or load module-adapter explicitly.
4. When ports appear: pw-play -> pipewire-played -> gate ALL GREEN
   (wav RMS check). Then: report is pre-written
   (docs/process/reports/2026-09-04-pipewire.md - update the PENDING
   line), board row in README-PHASE1.md, root README (~24.5% overall).


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
