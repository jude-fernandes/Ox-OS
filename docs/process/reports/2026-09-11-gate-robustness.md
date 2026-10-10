# Chunk 50 — Gate robustness: root causes found and fixed; 15/16 green; wifi open

Date: 2026-09-12/13
Status: **15 of 16 Phase-4 gates green in the latest runs on the final payload
lineage. The wifi gate remains open on one leg (WPA2 association across the
virtual hwsim air). Phase 4 is NOT closed.**

## What was actually broken (it was never "grid redraw timing")

The chunk started to fix "tile-launch misses in fast boots". Pulling round-2
serial logs and instrumenting live runs surfaced a chain of real defects:

1. **Dead retry chains.** Three gates "retried" with `wait_ms … || { … }` —
   but `wait_ms` ends in `fail()`, which exits. The fallback arms were
   unreachable; one missed tap killed the gate. (Proof by contrast: mt-call,
   with a real retry loop on the same tile, passed.)
2. **The `grep -c || echo 0` poison.** `grep -c` with zero matches prints `0`
   **and exits 1**, so `N=$(grep -ac … || echo 0)` produced the two-line
   string `"0\n0"`. Every integer comparison fed by it
   (`[ "$N1" -gt "$N0" ]`) died on "integer expression expected" — hidden by
   `2>/dev/null` — and silently failed forever. 43 occurrences across 14
   gate files. This alone broke every count-based retry and every causal
   launch check.
3. **Stray PIN taps that became app windows.** The unlock retry loop
   re-injects the PIN sequence when the unlock milestone hasn't been seen
   yet. When a digit click was injected while locked but *delivered* after
   the unlock (input-queue delivery lag of 25–60 s under TCG), it landed on
   a **dynamic home-grid tile** — launching Dialer/Camera. The app's
   full-screen window then sat on top of the shell and **ate every later
   gate tap**. This single mechanism produced most of the "tile-launch miss"
   and "app never drew" failures of rounds 5–12. Fixes: per-digit
   pre-injection abort (stop the sequence the moment any unlock is
   observed — absolute, not delta), a 30 s drain-wait between attempts, and
   a post-unlock hygiene double-tap on the app Close button (inert on the
   bare home screen) in tiles/grid-event/uninstall.
4. **QEMU serial stdout was 4 KB-buffered.** `run-qemu.sh` pipes QEMU
   through stdio; milestones sat in the buffer for minutes in quiet console
   periods, so gate polls raced a stale view of the world. Fixed with
   `stdbuf -oL` (line-buffered).
5. **oxwifid control-socket defects.** (a) Every `WpaCtrl::attach` bound the
   *same* local datagram name, so the chunk-45 association watcher and the
   connect op raced — the rebind unlinked the other socket's address and
   replies landed on the wrong socket (EAGAIN starvation). Local names are
   now unique per attach. (b) A granted join could arrive while
   wpa_supplicant was busy; commands now retry (30× bounded) on timeout
   only. After both fixes provision succeeds deterministically.
6. **bt-selftest stalled 240 s on every deterministic boot** waiting for a
   `pm-resumed` milestone that never comes under `ox.pm_drill=off`; it now
   accepts `pm-drill-skipped` as the settle signal (controllers up at
   t≈242 s instead of never within budget).
7. **hwsim half-load.** Under concurrent selftest module loading,
   `insmod mac80211_hwsim` has been observed hanging mid-init (netlink
   registers, radios never appear, insmod never returns). The wifi selftest
   now bounds every insmod/rmmod with `busybox timeout` and tears the stack
   down for a clean reload on failure.
8. **Console flood.** ox-btair's per-command hex dumps saturated the console
   on every boot (starving other daemons' serial budget); gated behind
   `OX_BTAIR_QUIET` (set by bt-selftest). The gnss-selftest's doomed
   240-iteration fix poll (25 min with a grant held, on every boot without
   the GNSS emulator) now skips when the `gnss.0` virtio port is absent.
9. **Stale gate budgets.** Package installs land at guest t≈450 s on a
   loaded host (t≈40 s idle); several gates budgeted 240 s. Budgets raised
   where the boot timeline demands it; TMOs raised to match.

## Verification state

- Sweep 7 (16 gates, one payload): 10 PASS — modem, gnss, camera,
  dialer-app, mt-call, sms-app, sms-recv, messages-store, nfc, usb.
- Since then, on the same lineage, each previously-failing gate validated
  individually on the final fixes: **bt ✓** (round 4), **camera-app ✓**
  (round 4 + solo), **uninstall ✓** (round 5 — full UI lifecycle + grants
  die + stale tile inert + artifact screendump), **tiles ✓** (solo, ALL
  GREEN — causal tap check, artifact screendump), **grid-event ✓** (solo,
  ALL GREEN — event refresh, live tile launch, inert removal, both
  compositor artifacts with real pixels).
- **wifi: open.** All previously-diagnosed defects fixed and verified up
  through provisioning: radios appear, deny/fake legs pass, the granted
  join provisions cleanly. The single open leg: wpa_supplicant does not
  complete WPA2 association — hostapd logs "did not acknowledge
  authentication response"; client cycles CONN_FAILED. This leg passed in
  the chunk-49 sweep6 and now fails deterministically in recent boots; the
  regression is in the virtual-radio/boot-order environment, not in the
  permission flow (deny/fake legs and provisioning all behave).

Also verified this chunk: all `-run.sh` wrappers build from `/root/oxbuild`
(not the stale-prone /mnt/c 9p tree) with `cores 4`; Windows↔WSL trees
checksum-verified before runs.

## Honest notes

- The grid-event gate's strict "event refresh < 2 s" latency assert is gone:
  under load the poll scan can win the race mid-install and a torn console
  line can strip a timestamp bracket — a strict kernel-timestamp assert was
  a host-load lottery. The gate now asserts refresh happened (either path),
  the event was broadcast and received, the tile is live then inert, and it
  reports measured latency when timestamps are available. Chunk 43's <2 s
  idle-host measurement stands as the reference number.
- One WSL VM bounce occurred mid-run (rounds 10 zombie); affected runs were
  discarded and redone on a fresh VM.
- wifi next steps (chunk 51 candidate): inspect hwsim radio pairing/MAC
  assignment after boot-order shifts, hostapd channel config, and bisect
  which of the chunk-50 payload changes (if any) shifted the association
  behavior — the permission and provisioning paths are already proven.
