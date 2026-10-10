# Wi-Fi: the credential store (persist + autojoin + forget) — chunk 45, Phase 4, 2026-09-11

## Claim

A granted Wi-Fi join now persists. oxwifid stores the credential in
/data/ox/wifi-credentials.json ONLY when a wifi.join-GRANTED
association actually completes (never on deny, never on fake, never
on a provision that didn't land), remembers the most recent networks
(deduped by ssid, capped at 8, atomic tmp+rename), AUTOJOINS the most
recent one on later boots — the driver replaying the user's earlier
consent, journaled as remembered=true — and a system `forget` op
removes a network (least privilege). The gate proves persistence the
only honest way: it REBOOTS the same data volume and requires the
cold boot to autojoin BEFORE the selftest's own join legs run
(line-ordering proof in the serial log), then re-walks the whole
permission matrix on the remembered boot and exercises forget.

## Stack layers (all gated)

1. **Daemon** (oxwifid): `remember_at/load_creds_at/forget_at`
   (unit-tested: round-trip, most-recent-last, dedupe, cap, forget
   semantics); the grant-join path marks the credential PENDING and
   an association watcher (2 s poll) persists it when the radio
   actually reports COMPLETED — journaling `wifi-joined` +
   `wifi-credential-stored` at the real completion moment; boot-time
   autojoin (waits for the wpa ctrl interface AND the /data mount,
   provisions + selects the most recent remembered network, 90 s
   budget, journals `wifi-autojoin-start` / `wifi-autojoined
   ssid=… remembered=true` / `wifi-autojoin-failed`); `forget`
   system op (root oxctl = the dialog tap) journals
   `wifi-forgot`.
2. **Selftest** (wifi-selftest): boot-type awareness — a FRESH
   device (no store) must boot DISCONNECTED (`wifi-no-factory-join`);
   a REMEMBERED boot must have autojoined (`wifi-autojoin-ok`), then
   disconnects itself (disable_network all) so the matrix is
   exercised from a clean state; after the granted join it waits for
   the daemon's persistence JOURNAL and then requires the store file
   (`wifi-credentials-stored`); remembered boots end with
   `wifi-forget-ok`.
3. **Gate** (wifi-gate.sh, now two-phase): phase 1 — the full
   chunk-42 flow (no factory join, deny/fake/grant, association,
   ICMP, scan, Settings panel) plus `wifi-credentials-stored`;
   phase 2 — kill QEMU, KEEP data.img, boot again on the same
   volume, require `wifi-autojoined` and prove by line numbers that
   it preceded the selftest's own walk, then the matrix re-walk and
   the forget leg. WIFI GATE ALL GREEN across both boots.

## Instructive findings

1. **Persistence must follow reality, not the RPC deadline.** The
   first run failed honestly: the connect op's association wait
   (25 s) timed out under TCG while the association landed a minute
   later — and the credential, stored only inside the op's success
   path, was lost. The selftest correctly refused to see a store
   that wasn't there. The fix moves persistence OUT of the RPC
   path: the connect op marks the credential pending; a watcher
   persists it when the radio reports COMPLETED. The daemon's join
   journal now fires at the real completion moment, not at the
   response moment.
2. **Two-boot gates need boot-type awareness in the selftest.** The
   remembered boot's autojoin made the radio COMPLETED before the
   matrix walk — which would have falsely tripped the fake-leg
   radio-clean assertion. The selftest now distinguishes fresh vs
   remembered boots and, on remembered ones, disconnects itself
   first so the deny/fake legs are exercised from a genuinely clean
   state.
3. **Ordering claims need line numbers, not vibes.** "Autojoin
   happened before the selftest walk" is checkable exactly: compare
   the serial-log line numbers of `wifi-autojoined` and the
   selftest's first join leg. Timing-based assertions (milestone
   appears within N seconds) would have been flaky at TCG speed.
4. **A two-boot gate is the only honest persistence proof.** Any
   single-boot check (file exists, state kept) can be satisfied by
   in-memory luck; rebooting the same data volume and requiring the
   cold boot to REPLAY the stored credential costs one more boot
   (~4 min) and buys a proof that actually matches the claim.

## Honest scope

- Autojoin covers the MOST RECENT remembered network only (single
  active credential slot, matching SELECT_NETWORK semantics); the
  store keeps up to 8 for the future network picker.
- Autojoin never prompts: if the remembered join fails, the daemon
  stays disconnected and journals the failure (a UI could offer
  rejoin; there is no UI for it yet).
- forget is authenticated only by the root socket (system surface),
  consistent with authorize in chunk 44.
- Credentials rest PLAINTEXT in /data/ox/wifi-credentials.json —
  /data is the LUKS-encrypted volume on the designed path, but no
  per-record sealing (keyring integration) exists yet.
- Autojoin and the PM system are untested together (suspend during a
  remembered boot's autojoin window): the drill settles before the
  selftest walk, but a real suspend/resume with an association in
  flight is future PM work.

## Verification artifacts

- Gate: `tools/wifi-gate.sh` (+ `-run.sh`) — WIFI GATE ALL GREEN
  across two boots; zero stray QEMU.
- Boot 1 milestones: `wifi-no-factory-join`, `wifi-join-denied-ok`,
  `wifi-join-fake-ok`, `wifi-join-fake-radio-clean`,
  `wifi-associated ssid=ox-virt-ap`, `wifi-join-grant-ok`,
  `wifi-credential-stored ssid=ox-virt-ap`,
  `wifi-credentials-stored ssid=ox-virt-ap`, `wifi-ping-ok`,
  `wifi-stack-ok`, `wifi-scan-found`.
- Boot 2 milestones (same data.img): `wifi-autojoined ssid=ox-virt-ap
  remembered=true` (line 3571) BEFORE `DBG-WIFI-JOIN-DENY` (line
  4128), full matrix re-walk, `wifi-forget-ok`.
- Workspace tests green (credential store round-trip/dedupe/cap/
  forget).
