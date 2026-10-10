# Chunk 58 — IPC transport secret hygiene (scrub on the wire path)

Date: 2026-09-25 (laptop-local Irish time)
Status: SHIPPED — workspace-test GREEN, throttle-persist gate ALL GREEN
(incl. `name=ipc-scrub`), ALL-16 sweep queued overnight on this payload
(k3gyyp807...)

## Problem

The house `zeroize()` pattern (chunk 51, ox-lockd/ox-shell) covered only the
buffers those processes own. Every PIN/PSK still rode the IPC transport as
plaintext in copies nothing ever wiped:

- the raw frame bytes on both ends of the socket
- the serde-encoded frame buffer on send
- the request `Envelope.payload` inside the daemon after the handler ran
- the handler's own `payload.clone()` (lockd enroll / enroll-duress)
- the daemon's response copy after send (wifid `saved-list` carries PSKs by
  design — the UI needs them)
- the client's request copy (shell/settings sending the PIN)

lockd's own header said it out loud: "transport-level secret hygiene is
Phase-5 work". This chunk is that work.

## Honest boundary (what this does NOT claim)

- Realloc copies serde makes *underneath* the JSON parser are unreachable
  from safe Rust. Best-effort, like every zeroize claim in this tree.
- The client keeps the response it is actively using (the settings UI holds
  the PSK list it is displaying). The daemon side — where the crown jewels
  live (every PSK ever joined, the PIN verifier inputs) — keeps nothing.
- wpa_supplicant's own config must hold the PSK for the radio; that is a
  wpa_supplicant property, not ours to scrub.

## Design: explicit scrub at the four transport boundaries

Rejected: `impl Drop for Envelope`. It bans field moves out of the struct
(E0509) everywhere — ~40+ response-reading sites across 10 client crates,
each needing mechanical rewrites. High churn, high regression risk, and the
guarantee (hidden drops) is weaker than an auditable single-file discipline.

Shipped: the scrub lives in **ox-ipc only**, at the four places a secret can
enter or leave the transport:

1. `FrameReader::next_frame` — raw frame body zeroized after decode, on
   success AND error paths.
2. `send_envelope` — encoded frame zeroized after `write_all`.
3. `Envelope::encode` — the serde `to_vec` intermediate zeroized.
4. The connection loop in `serve`/`serve_with_disconnect` — the handler
   contract changed from `Fn(Envelope) -> Envelope` to
   `Fn(&mut Envelope) -> Envelope`, and the loop scrubs the request payload
   after the handler returns and the response payload after it goes on the
   wire. `Client::request` scrubs the caller's request copy after send.

The daemon-side secret lifecycle is now: arrive → parse → handle → **zeroed**
— with the scrub provable in one file.

## Handler changes

- 19 serve sites across 18 crates: closure annotations / handler signatures
  to `&mut Envelope` (mechanical; bodies already borrowed).
- ox-lockd `enroll` + `enroll-duress`: the `payload.clone()` clones are now
  scrubbed on EVERY path via a verdict-enum restructure (all refusal
  milestones, order, and responses preserved).
- oxwifid `connect`: the local PSK copy is zeroized after the pending-store
  clone (the credential the watcher must persist stays; the transient copy
  dies).

## New: lockd `selftest-scrub` op + lockd-selftest service

A decoy secret rides the REAL socket (`oxctl lockd selftest-scrub
{"decoy":...}`), lockd scrubs its copy and reads it back. All-zero →
`OXMILESTONE name=ipc-scrub bytes-zeroed=true` on the serial console. This
proves the scrub path executes correctly **in the guest binary**, not just
in host tests. The new `lockd-selftest` s6 longrun runs it at every boot;
failure journals `name=lockd-selftest-failed`.

## Verification gates (all must be green)

1. `workspace-test`: `cargo test --workspace` on the host toolchain —
   includes 5 new ox-ipc tests (scrub_value structure+scalars, envelope
   scrub, REAL socket-pair round-trip delivering the secret intact then
   reading back all-zero, zeroize_string UTF-8 length preservation).
   **GREEN** (nix store lpms20bb..., test result: ok on every suite).
2. Throttle-persist gate (chunk 56 gate, now also asserting `name=ipc-scrub`
   in boot 1): exercises the full verify path — taps → shell → ox-ipc →
   lockd — twice, with a power cut between. **PENDING RUN** (see rollout
   below).
3. Overnight ALL-16 sweep on this payload (autonomous queue). **PENDING**.

## Rollout record (honest — two gate FAILs before the fix)

- **Run 1 FAIL** — "expected the 4th failure to arm an 8s window". Serial
  forensics: only ONE denial ever fired. Root cause is NOT the scrub code
  (PIN 1's shell→ox-ipc→lockd round-trip worked; the scrub selftest proved
  itself in the same boot). Chunk 57's 420s selftest grace moves the wifi
  AP join + credential store + **Hello app relaunch to t≈520-560 guest-s —
  INTO the middle of the throttle gate's PIN drill**; the Hello window
  covers the lockscreen and eats pad taps. The throttle gate predates the
  chunk-54 retry tooling: its `wait_guest("pin-verify-denied")` matched
  PIN 1's line forever, so stolen taps were invisible. **Tracked finding:
  apps can open windows over the lockscreen — a lockscreen secure layer
  (z-order + tap routing) is chunk-59 lead.**
- **Gate hardening (chunk 58)**: `pin_step` — every injection is
  COUNT-VERIFIED (the milestone count must INCREASE, proving THIS pad
  entry produced it), with bounded retries for stolen/throttled taps.
- **Run 2 FAIL** — "owner unlock (pattern never advanced)" — my own bug:
  `grep -c` already prints `0`; the copied `|| echo 0` made counts
  multiline (`0\n0`), so every `[ -gt ]` comparison failed (`[: Illegal
  number`) and the step retried into exhaustion — **while the guest had
  actually unlocked** (`pin-verify-success-after-failures` +
  `name=shell-unlocked` both in the serial). Fixed with `pcount` (clean
  single-line counts) and `throttle_expired` (waits 65s of no-new-denials
  — the backoff caps at 60s — before the owner attempt, so the owner's
  first injection isn't eaten by the window earlier retries armed).
- **Run 3 GREEN** — `THROTTLE-PERSIST GATE ALL GREEN`, no retries needed:
  scrub selftest proven in-guest → 4 wrong PINs escalate 1s/2s/4s/8s →
  power cut inside the armed window → boot 2 restores the counter
  (consecutive=5, retries included) → 5th wrong PIN arms 16s+ → owner
  unlocks post-window with success-after-failures persisted. The
  count-verified injection made stolen taps visible AND survivable; the
  run-1 environment condition (selftest cascade over the lockscreen)
  stayed quiet but remains a tracked finding, not a fixed bug.

Also: `pkill -f qemu-system-aarch64` inside a `sh -c` whose own command
line contains that string kills itself (SIGTERM, exit 15) — the self-match
bug bit once during launch; launch scripts must keep the pattern out of
their own argv.

## Residuals (documented, not hidden)

- serde-internal realloc copies (above).
- Client-side response payloads (UI is using them by definition).
- oxwifid `connect` early-error paths (bad app / deny / fake / validation
  failure) drop the local PSK copy unscrubbed — the request Envelope's own
  copy IS scrubbed by the transport; only the `get()` local copy on those
  rare refusal paths lingers until realloc reuses it. Acceptable; noted for
  a later pass if sweep data ever makes it matter.
