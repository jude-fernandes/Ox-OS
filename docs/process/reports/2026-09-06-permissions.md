# Manifest-permission binding — installs register what apps may ask for

Date: 2026-09-06
Status: **DONE — PKG GATE ALL GREEN (with permission lifecycle)**

## Scope

Phase 3 chunk 13: the manifest's `permissions` array stops being
parsed text and becomes the record users grant against.

- **permstored gained `bind {app, permissions}`** — install-time
  registration: each declared permission becomes a store entry at mode
  **deny** (installing an app grants nothing). Two invariants:
  1. **Reinstall never clobbers** — existing entries are left untouched,
     so an app update cannot resurrect permissions the user revoked or
     overwrite grants.
  2. **Persist-or-refuse** — the whole bind rolls back if the store
     write fails (same discipline as `set`; the store must never show
     state it failed to save).
- **intentd binds at install** — manifest parsing now validates
  `permissions` (optional; must be an array of non-empty strings) and a
  successful, signature-verified install registers the list with
  permstored, journaling `perm-bound app=<name> n=<newly bound>`.
  Bookkeeping is best-effort: enforcement is fail-closed at consult
  time regardless of whether the bind ran.
- **The hello package declares `post-notification`** — the rootfs
  build re-signs the manifest bytes, so the signature stays valid
  automatically (deterministic Ed25519 paying off).

## Gate

`tools/pkg-gate.sh` (further extended): after the install/verify legs,
the gate requires `perm-bound app=Hello`, and the boot selftest runs
the full permission lifecycle for the installed package:
1. post a notification AS Hello → **denied** (bound-as-deny, enforced
   through notifd's consult),
2. user grants via permstored →
3. post again → **accepted**.
`pkg-flow-ok` now asserts all of it. Artifact: `2026-09-06-signatures.png`
chain unchanged; the permission lifecycle is journal-verified.

## Honest limits

- There is no Settings UI for managing grants yet — grants are set via
  permstored ops (oxctl); the permissions panel is a UX chunk.
- Binding is bookkeeping: an app that never declares a permission is
  still denied everything (default deny at consult), so the security
  property does not depend on the manifest being complete.
- Notifd consults per post; other permission consumers (contacts,
  location, mic) arrive with their services in later phases.

## Verdict

**PKG GATE ALL GREEN** (2026-09-06): a signed install registers its
declared permissions as deny; the app is refused until the user grants;
after the grant it works. Default deny survives the entire pipeline.
