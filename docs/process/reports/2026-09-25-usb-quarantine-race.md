# Chunk 57: The USB quarantine race — sequenced by the guest clock

**Date:** 2026-09-25
**Verdict:** SHIPPED + **USB GATE ALL GREEN** with the fix.

## The race (root-caused)

The usb gate's strongest claim — "no /dev/sd* while quarantined" —
 intermittently failed in sweeps ("quarantined stick exposed a block
device"). Root cause: **two drivers, one stick.** The in-guest
usb-selftest explicitly waits for the gate's hot-plugged stick, runs
its permission matrix (fast), then **authorizes the gate's stick
itself** — while the host-side gate is still inside its
quarantine-assertion window. When the selftest's authorize landed
first, the block device appeared before the gate proved it shouldn't.
Load-dependent (selftest polling vs gate pacing), hence once-per-N
sweeps.

## The fix — sequenced by the guest clock (chunk-54 thinking)

The selftest now holds its authorize until the **guest's own clock
has advanced 420 s past the quarantine** (`/proc/uptime`-measured,
in-guest, host-speed-independent). The gate's no-blockdev assertion is
bounded by 360 guest-seconds of wait budget, so the grace provably
sequences the system-tap authorize AFTER the quarantine proof — no
matter how slow the host. The selftest's permission matrix (deny /
fake / grant with `authorized:false`) is unchanged and still runs
during the grace; only the authorize is held.

Downstream gate budgets for the matrix + authorize legs raised to 900
guest-seconds to absorb the new sequence.

## Rollout findings (all fixed same-chunk)

- **Silence caps were a regression risk**: wait_guest's "no serial
  output = dead guest" cap (600 s) could fire during the selftest's
  silent 420 s grace (an idle guest prints nothing for long stretches).
  All caps raised to 1800 s across the 14 gates. The right mental
  model: the silence cap bounds DEADNESS, never DURATION.
- **Per-wait budgets must exceed every upstream sequence step** — a
  360 guest-s budget downstream of a 420 guest-s grace can never pass.
  The budget audit is now part of the gate-review checklist.

## Validation

- USB gate ALL GREEN with the sequenced authorize: hot-plug →
  enumerated → QUARANTINED (no blockdev) → matrix → authorized (the
  selftest's tap) → blockdev appears → clean unplug.
- The guest-clock grace is host-speed-independent by construction —
  the same property that made the ALL-16 sweep possible.

## Honest scope

- The usb gate now runs ~7 guest-minutes longer (the grace). Sweeps
  get slower by that much per usb leg; determinism is worth it.
- The usb-selftest's authorize remains the in-guest system-tap
  simulation; production authorizes via the user's dialog tap.
