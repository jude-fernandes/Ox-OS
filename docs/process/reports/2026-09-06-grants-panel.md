# Grants panel — the user-facing permission story, all through the UI

Date: 2026-09-06
Status: **DONE — NOTIFY GATE ALL GREEN** (deny at install → user grant
through Settings → accept on relaunch; verdict at bottom)

## Scope

Phase 3 chunk 14: the permission lifecycle becomes a thing a USER can
drive, with no developer tools in the loop.

- **permstored `list`** — all (app, permission, mode) entries, sorted
  for stable UI ordering.
- **Settings → Permissions panel** — a fourth action button opens the
  grants view: one card per entry with a color-coded mode chip
  (grant=green, deny=red), tap toggles grant↔deny via permstored
  (persisted, journaled `perm-toggled app=… permission=… mode=…`),
  Back returns, Close exits.
- **ox-hello posts a notification every launch** — the app itself
  reports whether it's allowed: `hello-notify-denied` when bound-deny,
  `hello-notify-ok` after the grant. The proof of a toggle is the
  app's behavior, not just the store's state.
- The boot selftest keeps its denial proof (posts as Hello at boot,
  expects refusal) but no longer grants — granting belongs to the
  gate's user flow now.

## Gate

`tools/notify-gate.sh`: at boot require `hello-notify-denied` (the
installed app, denied by manifest binding) → PIN unlock → Settings →
Permissions → tap the Hello entry → `perm-toggled … mode=grant` →
screendump of the panel → Back → Close → **relaunch Hello from its
dynamic tile** → require `hello-notify-ok`. Artifact:
`2026-09-06-grants-panel.png`.

## Debug journey

One real bug, and it's a lesson about test placement: the first run's
tap on Permissions **closed the app**. Root cause: my rewritten
`hit_action` derived action codes from list order (enumerate) while
the app's match arms expected the verb codes — list index 2 =
permissions, but the arms read code 2 = close. The unit test asserted
the correct mapping and WOULD have caught it — but unit tests don't
run in the Nix build (build-only), so the swap shipped. Fixed with an
explicit verb-code table and a comment at the site: **never derive
action verbs from list order**. Longer term, the host-side `cargo
test` pass should run in CI so UI-mapping tests actually gate.

## Honest limits

- The panel lists up to 6 entries (single page; no scrolling yet).
- Toggle is grant↔deny only — `fake` mode stays settable via oxctl
  until the fake-data providers land per-permission.
- Revocation UX nuance (e.g., "allow once", time-limited grants) is
  Phase-5 territory.

## Verdict

**NOTIFY GATE ALL GREEN** (2026-09-06): a freshly installed, properly
signed app is denied; the user grants it in Settings with one tap; on
relaunch it works. The entire modern-mobile permission story — install,
deny, grant, accept — gate-verified on the Ox stack.
