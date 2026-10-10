# Chunk 61 — Input waits are process-scoped (SO_PEERCRED)

Date: 2026-09-28 (laptop-local Irish time)
Status: SHIPPED — workspace-test ALL GREEN, ACL GATE ALL GREEN (three
sides), LOCK-SHIELD GATE ALL GREEN, GRID EVENT GATE ALL GREEN

## Problem

Chunk 60 scoped mutations to owner-or-SYSTEM, but input waits stayed
open: any process could `key-recv` / `click-recv` / `gesture-recv` on a
window it did not own — an app registering click-recv on the lock pad's
window would read every tap position (and timing) of the PIN pad.
The app helper-connection pattern (chunk 50: window created on one
connection, clicks awaited on a second) is why per-CONNECTION ownership
could not simply be extended: the helper connection is a different
connection — and the boundary that matters is the PROCESS.

## Design: the kernel vouches for the pid

- **ox-ipc** stamps each connection's thread with the kernel-verified
  peer pid (SO_PEERCRED at accept, `libc::getsockopt`) and exposes
  `conn_peer_pid()`. No handler signatures changed — all 19 daemons
  keep their contracts; a client cannot self-report a pid.
- **oxcom** keeps `PROC_WINDOWS`: window-id lists keyed by peer pid
  (registered at window-new, removed in close_window_core). The input-
  wait dispatcher refuses `key/click/gesture-recv` for a foreign
  process's window, journaling the same `acl-refused` evidence class.
  The SYSTEM client (the shell) may observe anything; the helper-
  connection pattern works unchanged because both connections share
  one pid.
- The decision is a pure, unit-tested function:
  `input_wait_allowed(kind, pid, win) = kind == System ||
  proc_windows_contains(pid, win)` — with the registry semantics and
  the helper-pattern property each pinned by a test.
- A caught-during-review bug: the check initially gated EVERY op routed
  through the input dispatcher (win defaulting to 0) — restricting to
  the three recv ops is load-bearing and commented.

## In-guest proof

`acl-selftest` gained a fourth leg: oxctl is a DIFFERENT process from
the shell, so its `click-recv` on the pad's window must be refused
(`name=acl-input-refused op=click-recv`); the ACL gate waits for it.
The positive side is every app in the tree — each helper click-watcher
in the workspace exercises the allowed path continuously.

## Verification

1. **workspace-test ALL GREEN** — incl. `input_waits_are_process_scoped`
   and `helper_connections_of_one_process_share_ownership`.
2. **ACL GATE ALL GREEN** — SYSTEM (shell registers, shield engages),
   NORMAL (shield op + foreign close refused), INPUT (foreign
   click-recv on the pad refused), all guest-clock budgets.
3. **LOCK-SHIELD GATE ALL GREEN**, **GRID EVENT GATE ALL GREEN** on the
   same tree (regression + the new gate hardening below).

## Gate-infrastructure hardening (this chunk's rollout record)

- The 2026-09-27 overnight sweep failed 4 tap gates + lock-shield. Root
  causes, all fixed:
  - **lock-shield/acl gates used HOST-clock budgets** — the exact bug
    class chunk 54 eliminated; the probe launched at guest-t≈440s after
    the host budget had expired. Both gates migrated to `wait_guest`
    (guest-clock budgets, silence caps).
  - **The grid gate assumed Gridtest owned a fixed dynamic slot** —
    package-selftest timing reshuffles the sorted list boot-to-boot
    (the tap launched Dialer). The shell now journals the rendered
    dynamic row on every home draw (`name=home-grid dyn=...`) and the
    gate derives Gridtest's slot center from the last such line
    (`dyn_tile_rect` geometry), failing honestly if the slot is beyond
    the 4 rendered tiles. Proven live: row `Camera,Dialer,Gridtest,Hello`
    → slot 3 → launched.
  - Two self-side bugs on the way: an empty PAD id built invalid JSON
    (oxctl refused to parse — the selftest now waits for the shield
    milestone first), and a click-coordinate pattern that ignored QMP
    round-trip rounding (x=499 y=515 vs the computed 500,516 — matched
    with a 10px band and a comment).
- Earlier in the day: the sweep's own payload was built from a partial
  tree read (s6 services missing → lockd gone → unlock impossible →
  five hours of garbage). The sweep now verifies payload integrity
  (s6 service count tree==image, validated 56=56) before starting, and
  every gate runner builds `--offline` so a missing store path fails
  fast instead of hanging on DNS.

## Residuals (documented, not hidden)

- `sendkey` (input INJECTION) stays open — the compositor is the input
  root; gating injection needs the same treatment as screendump (a
  permstored consult), next security slice.
- A malicious process could still spam-connect; rate limiting is not a
  claimed property.
- Windows with pid 0 (unknown peer) are never registered — fails closed.
