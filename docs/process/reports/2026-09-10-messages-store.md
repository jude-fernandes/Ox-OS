# Messaging: the real store behind the synthetic contract — chunk 41, Phase 4, 2026-09-10

## Claim

The Phase-3 fake-providers contract for messages ("grant -> the real
store (/data/ox/messages.json), populated by the telephony stack")
had a comment where its writer should be. Chunk 41 ships the writer
with ZERO permission-layer changes: messagesd gains an ingest thread
that polls oxmodemd's snapshot as an un-attributed SYSTEM caller (the
daemon is the OS, not an app — no permstored consult on this path)
and appends every real SMS to the store — everything RECEIVED plus
every NON-synthetic send (fake-mode sends never touched the radio and
stay out of the real store) — deduped by (dir, id, number, text) with
the existing file seeding the seen-set, atomic tmp+rename writes,
each append journaled. An on-guest selftest walks deny/fake/grant
over that REAL data: deny refused, fake clearly synthetic and NOT
leaking the real text, grant returning the injected SMS verbatim
(synthetic:false, dir=in, from +15550042, "the eagle lands at
dawn"). The gate proves both ingest legs (the boot selftest's own
system-path send lands as dir=out; the gate's injection as dir=in)
and — after a regression this chunk found in itself — that the
legacy fake-providers contract still concludes green alongside the
new walker.

## Stack layers (all gated)

1. **Service** (oxmodemd, unchanged): the daemon inbox from chunk 39
   is the source; sms-list without app attribution serves the full
   snapshot to the system caller.
2. **Service** (messagesd): ingest thread (2 s poll of
   `sms-list {}`), `candidates_from_snapshot` (received + non-
   synthetic sent mapping — unit-tested), `merge_into_store` (dedupe
   keyed on the full tuple because radio ids reset per boot; the
   store file seeds the seen-set; atomic rename — unit-tested incl.
   the reboot-duplicate case), per-record `messages-ingested dir=
   … number=… text=…` journals. The list handler itself is untouched.
3. **Selftest** (messages-store-selftest, new s6 longrun): waits for
   the ingest, then walks deny/fake/grant with an explicit no-leak
   check (the fake response must not contain the injected text), and
   restores deny. Walks its OWN app id (messages.store) — see
   finding 1.
4. **Verification**: messages-store-gate ALL GREEN (GATE-EXIT=0):
   dir=out ingest of the boot SMS -> injection of +15550042 ->
   modem-sms-received -> messages-ingested dir=in -> the matrix over
   real data -> legacy `messages-test-ok` + `location-test-ok` still
   firing. Workspace tests green.

## Instructive findings

1. **Two selftests, one permstored row, one wedged daemon.** The
   first gate run passed ITS milestones while silently corrupting
   fake-providers-selftest: both walkers flipped
   messages.test/messages.read concurrently, producing a shifted
   mode sequence (deny query served fake data, fake query served
   REAL data, grant query denied). The perm journal shows 7 unique
   entries where 8 sets were issued — one walker's final restore-set
   never completed, and its oxctl (no timeout) hung before the
   verdict echoes, so neither messages-test-ok nor -failed ever
   printed. My own gate went green while a legacy contract's
   selftest was stuck: green gates prove what they GREP, nothing
   more. Fixes: the new walker uses its own app id (permstored modes
   are per (app,permission); an unbound app defaults to deny, so the
   walk is self-contained), and the gate now REQUIRES the legacy
   verdict milestones. The same-row concurrent-write wedge itself is
   flagged for permstored robustness work (single set lost/hung
   under same-row races; different-row concurrency has been running
   green for many boots).
2. **The gate must grep the neighbors it can break.** Related to
   chunk 37's Gridtest lesson: a chunk's regression can land in
   another service's milestones. Any chunk that adds a writer/walker
   to shared state re-proves the adjacent contracts in the same run.
3. **Radio ids are per-boot; identities must be tuples.** Same lesson
   as chunk 39's monotonic inbox ids, applied to persistence: after
   a reboot the emulator's +CMGS counter restarts at 1, so the store
   dedupes on (dir, id, number, text) and seeds from the existing
   file — a rebooted device re-ingesting the same message appends
   nothing.
4. **The system-caller split earns its keep.** messagesd polls
   sms-list with NO app field: no permstored consult, no log spam,
   no permission bypass (the inbox was already served to system
   callers by design). The attribute-or-be-system rule from chunk 38
   is what makes a daemon-to-daemon poll clean.

## Honest scope

- The store holds one boolean direction per record (in/out), number,
  text, radio id — no timestamps (the emulator's CMGR header carries
  a fixed date; real timestamps need a radio clock, future work), no
  conversations/threads, no read state.
- No UI consumes messagesd's list yet — the Messaging app still
  reads oxmodemd's inbox directly; pointing it at messagesd (and
  unifying on messages.read) is deliberately left for the
  inbox-UI unification pass.
- Synthetic sends are excluded from the real store by design; their
  honesty lives in the app's SYNTHETIC label and the daemon journal.
- The permstored same-row race is mitigated (one walker per row) but
  not fixed at the daemon level.

## Verification artifacts

- Gate: `tools/messages-store-gate.sh` (+ `-run.sh`) — MESSAGES
  STORE GATE ALL GREEN, GATE-EXIT=0; zero stray QEMU.
- Serial milestones: `messages-ingested dir=out number=+15550001
  text=ox-sms-test`, `modem-sms-received from=+15550042`,
  `messages-ingested dir=in number=+15550042 text=the eagle lands at
  dawn`, `messages-real-sms-ok`, `messages-test-ok`,
  `location-test-ok`.
- The granted list response (DBG-STORE-GRANT) contains exactly the
  two real records with `"synthetic":false`.
