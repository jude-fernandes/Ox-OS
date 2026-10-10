# Chunk 55: The click-drop fix — compositor input path under load

**Date:** 2026-09-24 (overnight run queued)
**Verdict:** fix shipped (compiled + unit-tested + payload rebuilt);
grid-event — the thrice-flaky gate — **ALL GREEN** on the fixed
payload; the full 16-gate sweep with every fix is running overnight.

## The isolated bug

After chunk 54 removed the host-clock false failures, two gates still
failed on the same signature: taps injected at a coordinate, the
guest clock advancing, and the shell never reacting (grid tile taps;
earlier the wifi Settings tap). Root cause found in oxcom's pointer
path (`pointer.rs`):

1. **Press→Up window mismatch, silent drop.** Down records the pressed
   window id; Up looks that id up in the CURRENT window list. Grid
   refreshes (and any window churn) close/recreate windows mid-gesture
   — when the id is gone, the click was dropped with no else branch
   and no journal. Fixed: on a vanished window, oxcom re-hit-tests the
   press point and delivers to whatever window sits there now, with a
   `click-rewindow` journal; an empty result still journals.
2. **Queue overflow, silent eviction.** EventHub::push evicted the
   oldest click at cap 32 with no trace. Fixed: `click-drop
   reason=queue-full` journal + cap raised to 128 (a click is bytes;
   the consumer loop is the real bound).

## Found by its own rollout

The first re-run failed EARLIER in the gate — "pkg selftest did not
settle" — which exposed a chunk-54 bug: guest budgets had been mapped
1:1 from host seconds. The serial log showed `pkg-flow-ok` landing at
guest t=562 s against a 360 guest-second budget — missed by 2 guest-
seconds. All guest budgets scaled ×3 (92 waits + 6 taps), silence caps
stay at 600 s. Grid immediately went ALL GREEN.

## Validation

- ox-workspace-test (compiles every crate + unit tests): green.
- grid-event solo (the failing gate, under boot-selftest load):
  **ALL GREEN** — install/remove land <2 s, tile live then inert.
- **CONFIRMED IN-SWEEP: the Sep 24 overnight sweep ran ALL 16 GATES
  green in one pass — grid-event included — with zero retries
  (PHASE4 SWEEP ALL GREEN, first in project history).**

## Honest scope

- The usb enumeration-to-quarantine race (chunk-46 gap) remains the
  second known intermittent — kernel-side plug defaults are the honest
  closure, tracked for a later chunk.
- The rewindow delivery means a tap on a vanished window now lands on
  whatever replaced it at that point — the semantics a touchscreen
  user expects; no gate asserted the old drop behavior.
