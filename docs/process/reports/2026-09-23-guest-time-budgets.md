# Chunk 54: Guest-time budgets — shipped, validated, one real bug isolated

**Date:** 2026-09-23 (overnight + evening)
**Verdict:** SHIPPED for 14 of 16 gates (~105 wait sites + 6 tap loops on
guest time). **CONFIRMED: the first ALL-16 single-payload sweep landed
Sep 24 00:3x (16 PASS, PHASE4 SWEEP ALL GREEN, zero retries needed) —
including grid-event and usb, the two gates that had never co-existed
green in one sweep before.** Report below retains the pre-confirmation
state for the record.

## What shipped

- `tools/gate-lib.sh`: `guest_ts` (parses the guest's kernel clock from
  serial), `wait_guest PATTERN GUEST_MS HOST_CAP LABEL` (pass on
  pattern; fail when the guest's own clock advances GUEST_MS, or when
  the serial log is silent HOST_CAP seconds = dead guest), and
  `tap_until_guest` (tap retries under the same deadline). Unit tests:
  parser verified against real serial lines incl. mid-line kernel
  prefixes, multi-line growth, empty log.
- 14 gates migrated: wifi, camera-app, grid-event, dialer-app, mt-call,
  sms-app, sms-recv, messages-store, nfc, usb, tiles, uninstall, bt,
  camera. Every gate now fails only when the GUEST had real time to
  progress and didn't — never because the host machine had a slow hour.

## Live validation

- wifi gate: GREEN on guest-time (14-min solo run) and PASS in-sweep.
- camera-app: GREEN solo (5-min run) + PASS in-sweep.
- uninstall: GREEN completing the interrupted 15/16 sweep cohort.
- Full sweep (Sep 23): 14/16 — the nine gates that collapsed to
  fast-fail in previous runs all passed under guest time; the gates
  slowed (6 → 45 min) as the VM aged but did NOT falsely fail.

## The migration bug found by its own rollout (fixed)

The first migration carried a 240 s **silence cap** (no serial output
= dead guest) that could trip EARLIER than the original 360–900 s host
budgets it replaced: a quiet-but-alive guest (TCG stall, no console
output) hit the cap and failed a wait the old code would have passed.
usb + grid failed exactly this way. Fix: all silence caps raised to
600 s across all gates; usb immediately went GREEN post-fix.

## The two residual failures — one real bug isolated

1. **grid-event**: "Gridtest tile did not launch" — taps injected at
   the tile coordinate, guest clock advancing, but the shell never
   emits intent-start. Same signature as wifi's old Settings-tap
   failure: under specific load states the compositor's input path
   stops delivering injected clicks to the shell. This is a REAL
   product-bug candidate in oxcom's click hub (chunk-50 saw its cousin
   in ox-term: "drain-then-draw input loop"). Chunk-55 lead item:
   instrument oxcom's input path, find the drop, fix the hub.
2. **usb**: "quarantined stick exposed a block device" — the <500 ms
   enumeration-to-quarantine race (chunk-46 known gap) fired under
   sweep load for the first time. GREEN immediately post-cap-fix, but
   the race is real; the kernel-side fix (plug-time authorized=0
   defaults) remains the honest closure.

## Machine log (for the record)

Host-laptop sleep killed three runs across the weekend (the watcher's
job-recovery now re-queues them automatically — proven repeatedly).
The task-launcher occasionally races cold VM starts and needs
`schtasks /End` of the stale instance; manual background launches are
the reliable fallback. GC moved to weekly (daily ate the build
toolchain three times — a 6 h rebuild tax for ~15 GB); kernel+payload
gcroots in gcroots/auto verified intact at byte level. Storage: vhdx
compacted 227 GB → 68 GB on user request (C: 150 → 298 GB free).

## Honest scope

- grid-event + usb remain red-in-sweep until the two bugs above close.
- The remaining two un-migrated gates (none in the Phase-4 sixteen)
  and any NEW gates should source gate-lib.sh from birth.
- The sweep verdict record: 14/16 (Sep 23) with both failures
  understood; ALL-16 remains open pending the oxcom input fix.
