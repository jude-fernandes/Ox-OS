# Chunk 56: Lockout persistence — the backoff survives a power cycle

**Date:** 2026-09-25
**Verdict:** SHIPPED + GATE ALL GREEN (`tools/throttle-persist-gate.sh`,
two boots, one data volume).

## The gap this closes

The lockout backoff (chunk 45: 1s→2s→4s…60s on consecutive wrong
PINs) lived in RAM. An attacker with a locked phone could clear it by
holding the power button — every reboot reset the counter to zero and
the offline brute-force budget back to unlimited. Duress/panic state
had the same hole.

## What shipped

- lockd's `Throttle` moved from `Instant` to `SystemTime` (wall clock
  survives reboots) and persists after EVERY verify outcome:
  `/data/ox/lock.throttle`, format
  `v1:<consecutive>:<delay_epoch_ms>:<nonce_hex>:<hmac_hex>` —
  HMAC-SHA256 (ox-pay-proto, RFC-vector-tested) with a per-install
  32-byte urandom key at `/data/ox/lock.throttle.key` (created on
  first persist). Atomic tmp+rename, house style.
- Boot: the record is restored and verified; a tampered record is
  rejected fail-open (the owner is never punished for tampering they
  cannot have caused from a locked device) with a fresh state.
- panic-wipe destroys both files (the wipe list grew by two paths).
- Journaling: `throttle-restored consecutive=N` / `throttle-fresh` at
  boot; the existing denial journals now prove persistence (the armed
  window after a reboot reveals the restored counter).

## The gate (two boots, one data volume)

Boot 1: four wrong PINs — denial journals escalate 1000 → 2000 →
4000 → 8000 ms; QEMU killed inside the armed 16s window. Boot 2 (same
volume): the 5th wrong PIN armed **16000 ms** — consecutive=4 was
RESTORED (a fresh state arms 1000). Owner then unlocks with the real
PIN after waiting out the window: `pin-verify-success-after-failures`
— and the reset itself persists (reloaded consecutive=0).

Unit tests: round-trip, HMAC tamper rejection, escalation across a
simulated reboot, owner-reset persistence. One run variance is
documented: a duplicated-OK injection (the known QMP tap-lag artifact)
can shift the counter by one — the gate asserts the invariant
(≥16s armed = counter ≥4 survived) rather than an exact value.

## Rollout bugs found by the build (both fixed same-chunk)

- `format!` vs `format` typos in the new code (caught by the
  workspace build).
- The HMAC key helper's write line targeted the production constant
  instead of the caller's path — invisible until the unit tests
  failed with `load_at: mac mismatch` (the diagnostics added to
  `load_at` pointed straight at it: same body, different key). Lesson:
  `let _ =` on fs writes in key management is a silent-corruption
  invitation.

## Honest scope

- The HMAC key lives on the same LUKS volume as the record — the
  threat model is the locked-device power cycle, not an offline mount
  (an offline attacker with the volume key is a hardware-phase
  problem).
- A sufficiently long power-off (past the 60s cap) still expires the
  delay window — but the CONSECUTIVE count never resets, so re-arming
  is immediate and each wrong PIN re-escalates. The counter is the
  durable part; the wait is the cosmetic part.
- Clock changes (manual time set) move `delay_until` — a locked
  device offers no clock-setting surface; noted for the hardware phase.
