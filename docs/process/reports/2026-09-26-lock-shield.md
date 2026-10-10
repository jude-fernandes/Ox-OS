# Chunk 59 — Lockscreen secure layer (the shield)

Date: 2026-09-26 (laptop-local Irish time)
Status: SHIPPED — workspace-test ALL GREEN, lock-shield gate ALL GREEN
(payload 81k938x1jy5m4qia1vncja058kb4jbmz)

## Problem

Found live by the chunk-58 throttle-gate rollout: chunk 57's 420s selftest
grace moved the wifi AP join + Hello app relaunch INTO the middle of the
PIN drill — and the relaunched app's window **covered the lock pad and ate
PIN taps**. Apps could composite above the lockscreen and receive (or
silently swallow) taps meant for the pad: tapjacking against the most
sensitive surface on the device. Worse, it was timing-dependent — the same
class of race that bit wifi (chunk 55) and USB (chunk 57).

## Design: a secure TIER in the compositor, not another timing hack

The compositor's z-order is a plain vec (later = on top). Chunk 59 adds a
`secure` flag on Window and one invariant, enforced at every mutation
point in `scene.rs`:

- **window_new** — a new window inserts at the FIRST secure position:
  directly below any secure window, above the normal tier. An app
  launched while the shield is up physically cannot land above it.
- **window_raise** — raises within the window's own tier: secure to the
  top of everything, normal only to the top of the normal tier.
- **window_set_secure(id, on)** — moves a window into/out of the tier,
  order-preserving within tiers.
- **hit_test** — unchanged logic; the tier invariant makes it return the
  shield whenever the shield covers the point.
- **hit_all** (new) — every window under a point, topmost first; the tap
  evidence source.

Ordering is enforced by construction (insert position), not by retry or
grace windows — the chunk-55/57 lesson applied to z-order.

## Plumbing

- oxcom `window-secure` op (`{"id", "on"}`): idempotent, full repaint on
  tier change, journals `OXMILESTONE name=lock-shield id=N on=true|false`,
  focuses the shield when engaged.
- oxcom pointer Down path: when a tap lands where a secure window sits
  above others, journals
  `OXMILESTONE name=lock-shield-kept win=N shadowed=M` — tapjacking
  evidence is a permanent serial record, never silent.
- ox-shell flips the shield on its three lock transitions: boot
  (`shell-locked`), unlock (`shell-unlocked` → off), footer relock
  (`shell-relocked` → on). The shield's owner is the shell; nothing else
  calls the op (root-only 0600 IPC, same trust surface as window-new).

## In-guest probe: shield-selftest

New s6 longrun: waits for `lock-shield on=true`, then launches Hello
**while the device is locked** — recreating the exact chunk-58 condition
on every boot. Hello is packaged by pkg-selftest, which can run before or
after this selftest (boot-order variance), so the start retries until
packaged (idempotent op — whoever lands the first start wins).

## Verification: LOCK-SHIELD GATE ALL GREEN (five legs, one boot)

1. Shield engages at boot (`lock-shield on=true`).
2. Hello starts while locked; its window (id=6, x=190 y=80 w=900 h=680 —
   covering the pad) is created BELOW the shield.
3. A pad tap journals `lock-shield-kept win=2 shadowed=6` AND the pad
   receives the digit (`entered=1`) — the tap reaches the pad, the
   covered app gets nothing, and the evidence line is on the serial.
4. Owner unlock (1234) → `shell-unlocked` + `lock-shield on=false` — the
   grid competes normally again.
5. Footer Lock tap → `shell-relocked` + shield re-engages (count-verified).

Unit tests (oxcom scene): shield_tier_blocks_raise_and_new_windows,
shield_release_restores_normal_z_order, shield_unknown_and_degenerate_cases
— 38 oxcom tests pass.

## Rollout record (honest — four gate FAILs before green, all gate-side)

- **Night run 1 (test-gate)**: my own test had a wrong premise — the pad
  covers the whole screen, so any point inside a window "over" it
  hit-tests to the shield (that IS the tier property); the test expected
  the app. Fixed with a window outside the pad's rect. This one test also
  failed the payload build (payload depends on workspace-test), which is
  why lock-shield-gate-run's BUILD FAILED the same night — one root cause,
  two red rows.
- **Gate run 2**: "shield did not journal the redirected tap" — the guest
  was CORRECT (serial showed lock-shield-kept win=2 shadowed=6 + pad
  entered=1). The gate grabbed "last window-new" right after intent-start
  and caught a status window (id=5) instead of Hello (id=6, created 0.7s
  later).
- **Gate run 3**: the race flipped — Hello's window-new landed BEFORE the
  gate's baseline count (intent-start fires 0.7s before window-new; the
  2s poll crossed it). Baseline moved to post-shield-engage, pre-launch.
- **Gate run 4**: "footer relock never fired" — my tap aimed at y=752 on a
  700px screen. Lock button center is (123, 652).
- **Gate run 5**: "Hello never intent-started" — root-caused to BOOT-ORDER
  variance: the probe fired at t≈26s, Hello was packaged at t≈410s
  (pkg-selftest), the single attempt got app-not-packaged. Fixed IN THE
  GUEST (selftest retries until packaged) — the durable fix, not a gate
  hack.
- **Gate run 6: ALL GREEN.**

## Residuals (documented, not hidden)

- The shield covers the shell's full window; a future dialer/alarm
  overlay above the lockscreen would need its own secure flag — the tier
  mechanism already supports multiple secure windows (stack order among
  them = creation order).
- `window-secure` is callable by any root-IPC client (like every oxcom
  op today); per-client op ACLs remain Phase-5 security work (tracked
  since Phase 3).
- The duress path unlock also releases the shield (correct: it IS an
  unlock), then panic-wipes — unchanged behavior, now with the shield
  cycling correctly.
