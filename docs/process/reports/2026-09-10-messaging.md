# Messaging: SMS through the UI — chunk 38, Phase 4, 2026-09-10

## Claim

Ox OS sends REAL SMS from a tappable Messaging app under the honest-
permission contract. oxmodemd's `sms-send` op becomes permission-
checked like dial: an app-attributed send consults permstored
`telephony.sms` (fail-closed) — deny refuses, fake produces a
SYNTHETIC record the radio never sees, grant sends for real through
the two-phase CMGS engine. The Messaging app — a signed .oxp package
(Dialer pattern) — draws a recipient pad plus an a–z text keyboard,
and its sends are REFUSED while telephony.sms is bound deny, then go
to the radio once the user grants. The gate proves the full lifecycle
and the emulator's log confirms the radio received exactly
`+15550001: 'hi'`. The three dynamic-tile gates were re-proven on the
new payload (the rootfs stages one more package; sorted-grid slots
were derived to be unchanged and that held).

## Stack layers (all gated)

1. **Service** (oxmodemd): `sms-send` arm gains the policy layer —
   `mode_for(app, permission)` generalizes the consult (dial/hangup
   pass `telephony.dial`; SMS passes `telephony.sms`), deny refused,
   fake = local `SmsRec{synthetic:true}` (id allocated, kept in
   state, `modem-sms … synthetic=true` journaled), grant = the
   egress-journaled two-phase CMGS path returning
   `synthetic=false`. Un-attributed sends (root `oxctl` selftests)
   keep the legacy journaled path — app-identity binding is a later
   chunk; the attribution decision is journaled either way. E.164 +
   printable-ASCII validation unchanged and unit-tested.
2. **App** (ox-sms, signed sms.oxp, manifest binds
   telephony.sms=deny on install): 12-key recipient pad (Dialer
   geometry, tighter cells) + 28-key text keyboard (a–z, backspace,
   space — 7×4), compose preview, Send/Close, honest states — refused
   send surfaces the denial (`sms-send-denied`), fake sends labeled
   SYNTHETIC, real sends journaled `sms-sent … synthetic=false`.
   Drain-then-draw-once input loop (chunk-37 lesson applied from the
   start), wake lock app-messaging.
3. **Verification**: messaging batch ALL FOUR GATES GREEN —
   sms-app-gate (install → tile tap → compose +15550001 "hi" → send
   refused (bound deny) → grant → radio send confirmed in the
   EMULATOR log (`SMS-SENT to +15550001: 'hi'`) → Close → reap) plus
   re-proofs of tiles-gate, grid-event-gate (install/remove refresh
   0.07s/0.36s, screendumps show real content) and uninstall-gate
   (grants die with the package).

## Instructive findings

1. **Sorted dynamic grid made the fourth package free — on purpose,
   not by luck.** `Messaging` sorts after `Camera`/`Dialer`/`Hello`
   and before nothing that matters, so every existing tile tap stayed
   valid; and when grid-selftest's Gridtest arrives there are FIVE
   installed apps against a four-slot grid, so `take(4)` keeps
   [Camera, Dialer, Gridtest, Hello] and silently drops Messaging
   instead of shifting the gates' tiles. The
   rule going forward: new package names must sort AFTER the gates'
   existing tile names, or every tile coordinate is load-bearing
   again.
2. **The permission consult key is app attribution, and the system
   path must stay open.** modem-selftest (chunk 30) sends SMS as root
   oxctl with no `app` field; making attribution mandatory would have
   broken that green gate or forced it to pose as an app. The split:
   attributed requests are policy-checked, un-attributed ones are
   system callers on the legacy journaled path. Documented in the
   daemon, visible in the emulator log (both `ox-sms-test` from the
   selftest and `hi` from the app appear as separate SMS-SENT lines).
3. **Encoding a keyboard as one packed string per row is a trap.**
   `"vwxyz<-sp"` iterates as NINE single-char keys (`<`, `-`, `s`,
   `p`) — the two-character key labels silently fragment. Explicit
   per-row arrays (`[&[&str]; 4]`) make the 7×4 grid and the
   backspace/space actions impossible to mis-encode, and the unit
   test asserts the letters concatenate to the alphabet in order.
4. **Gate tap math is window-origin + layout constants.** The
   Messaging taps are (60,90) + pad origin (80,180) strides (80,56)
   and keyboard origin (350,180) strides (78,50); the Close button
   lands at the same screen point as the Dialer's (877,662) because
   both apps use the same window and close-rect formula. Deriving
   them in the report makes the next gate cheaper to audit.

## Honest scope

- One-way sends only: no message list/conversation view, no received-
  message path (`+CMTI`/`+CMT` still parked as URCs), no delivery
  reports, no concatenated SMS (160-byte printable-ASCII cap).
- App identity is still the payload's own `app` string (honor-system,
  as for dial); sandbox-level attribution is future work on the
  roadmap.
- Fake mode is exercised by the policy surface and unit tests but not
  by this gate (the gate walks deny → grant); the fake path is the
  same code the Dialer gate already proved for dial.

## Verification artifacts

- Batch: `tools/messaging-batch.sh` — ALL FOUR GATES GREEN.
- Serial milestones: `sms-app-installed`, `sms-ready`,
  `sms-send-denied error=telephony.sms denied`, `sms-app-granted`,
  `sms-sent to=+15550001 text=hi synthetic=false`, `sms-exit`,
  `intent-exit app=Messaging code=0`.
- Emulator log: `SMS-SENT to +15550001: 'hi'` (and the selftest's own
  `SMS-SENT to +15550001: 'ox-sms-test'` on the system path).
- Cargo workspace tests green (ox-sms geometry/action tests, oxmodemd
  validation tests).
