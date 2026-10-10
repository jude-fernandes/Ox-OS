# Per-service fake providers: location + messages — chunk 25, 2026-09-08

## Claim

The charter's honest-permission feature now covers all three sensitive
data services, not just contacts. New daemons **ox-locationd** and
**ox-messagesd** follow the contactsd shape exactly: every consult
checks permstored per app and is served by mode —
**deny** (default, incl. unbound/unreachable) refused ·
**fake** synthetic data (`synthetic:true`) ·
**grant** the real store. Every consult is journaled with the mode
served (`location-consult app=… mode=…` / `messages-consult app=… mode=…`).

## Design decisions worth recording

- **Location's grant mode never fabricates.** The real store
  (`/data/ox/location.json`) is written by the GNSS stack when a fix
  exists. On the virtual target there is no GNSS, so a granted query
  answers `{"fix":null,"synthetic":false}` — the honest "no fix", never
  a made-up coordinate. The fake mode's synthetic fix claims a 5 km
  accuracy circle and is labeled `"synthetic fix"` — impossible to
  mistake for a real position.
- **Messages** mirror contacts exactly: synthetic conversations are
  visibly fake (`Fake Alice` / `+1-555-01xx` / "synthetic message …"),
  the real store starts empty on a fresh device, and garbage in the
  store degrades to empty rather than crashing the service.
- Fail-closed everywhere: an unreachable permstored means deny, in all
  three services.
- Permission names: `location.read`, `messages.read` (alongside
  `contacts.read`, `post-notification`).

## Gate evidence (`tools/fake-providers-gate.sh` ALL GREEN)

A new boot selftest (`fake-providers-selftest`) walks all three modes
for `location.test` and `messages.test` through `oxctl`; the gate
requires every `*-consult app=… mode=…` journal line plus the
selftest's `location-test-ok` / `messages-test-ok`, and prints the
fake/grant payloads:

- location fake: `{"fix":{"accuracy_m":5000,"label":"synthetic fix",
  "lat":51.5072,"lon":-0.1276},"synthetic":true}`
- location grant: `{"fix":null,"synthetic":false}` — honest no-fix
- messages fake: 3 synthetic messages from Fake Alice/Bob/Carol
- both modes restored to deny afterwards (least privilege)

Workspace unit-test gate (runs inside the payload build) covers the
new code: synthetic-data shape assertions and the missing/garbage
store behavior.

## Wiring

- `ox-locationd` / `ox-messagesd` added to the workspace, the
  guest-daemons Nix build, the rootfs bin set, the s6-rc graph
  (longruns) and the default bundle; `fake-providers-selftest` joins
  `contacts-selftest` and `grid-selftest` as boot-time verification.
- `Cargo.lock` updated (hand-registered the two path-dependency
  members; the offline `cargo update` path needs a network-backed
  registry cache the host doesn't have — noted for future crate
  additions).

## Instructive findings

1. **Windows text-mode rewrites break s6 bundles.** The `default/contents`
   bundle was edited from Windows in Python text mode, which rewrote
   EVERY line with CRLF — s6-rc-compile then saw `oxcom\r` as an
   undefined service name and failed the whole payload build. Any file
   consumed by bash/s6 (nix buildPhases, s6-rc sources, gate scripts)
   must be CRLF-cleaned after host-side edits; now done for
   `default/contents`, `Cargo.toml`, `Cargo.lock`.
