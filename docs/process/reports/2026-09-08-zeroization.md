# Secret zeroization — chunk 28, 2026-09-08

## Claim

PIN material no longer lingers in memory longer than it must: the
shell's typed-digit buffer is zeroized on every terminal path (and on
drop), lockd zeroizes every scratch buffer that carries the raw PIN
and the salt+hash when a verifier is replaced or dropped, and the
panic wipe now extends to RAM — the running daemon stops
authenticating the old PIN immediately, not just after a reboot.

## What was actually wrong (two real findings)

1. **The shell kept the typed PIN after a successful unlock.** The
   buffer was cleared on reject/throttle/relock but NOT on the success
   path — the PIN sat in memory for the entire unlocked session. Now
   every terminal path clears it.
2. **Panic wipe did not extend to RAM.** The wipe deleted the secret
   files but left the live `PinVerifier` in lockd's memory: until
   reboot, the daemon kept authenticating the old PIN — against the
   charter's promise that a duress unlock hands over "a device with no
   secrets left". The wipe now swaps the verifier for an unusable
   zeroed placeholder (whose `Drop` zeroizes the old salt+hash) and
   resets the throttle state.

## Implementation

- **`zeroize(buf)`** (shell + lockd): volatile per-byte zero writes +
  a compiler fence — a plain zeroing loop on a soon-dropped buffer is
  dead-code-eliminable; this one is not. Honest boundary, documented in
  the code: the IPC transport still holds transient JSON copies of the
  PIN that we do not own; transport-level secret hygiene belongs to
  the Phase-5 key-hierarchy work.
- **`PinEntry`** (shell): the typed-PIN buffer as a byte vector with a
  cap, a `clear()` that zeroizes before truncating, and a `Drop` that
  zeroizes whatever remains.
- **lockd**: `hash_pin` zeroizes every scratch buffer that carries the
  raw PIN (verify, enroll, and all 4096 stretching rounds);
  `PinVerifier` now has a `Drop` that zeroizes salt+hash — rotation
  and duress verification (which loads a fresh verifier per call) get
  this for free.

## Verification

- **PIN GATE ALL GREEN** (the full security gate re-run as the
  no-regression proof): rotation self-verified on the pad, relock,
  old-PIN rejected, new PIN unlocks, five-wrong-PIN throttle drill
  (sixth verify surfaced as throttled, owner unlocks after the
  window), duress unlock flagged, and the panic wipe — now with RAM
  zeroization — executed and journaled.
- Workspace unit tests (run inside the payload build) added:
  `zeroize_overwrites_the_whole_buffer` (both crates),
  `pin_entry_buffer_caps_clears_and_stays_ascii`,
  `pin_entry_clear_zeroizes_the_backing_bytes`,
  `zeroed_placeholder_verifier_never_authenticates` (no PIN verifies
  against the post-wipe placeholder).
