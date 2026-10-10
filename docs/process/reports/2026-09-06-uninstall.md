# Uninstall — the package lifecycle closes through the UI

Date: 2026-09-06
Status: **DONE — UNINSTALL GATE ALL GREEN** (verdict at bottom)

## Scope

Phase 3 chunk 16: what install begins, uninstall ends — through the
UI, with the security consequences handled.

- **permstored `unbind {app}`** — uninstall removes the app's
  permission entries entirely: **grants die with the app**. Same
  persist-or-rollback discipline as every store mutation (entries are
  restored if the write fails).
- **intentd `remove` hardened** — refuses to remove a *running* app
  (`app-is-running`), and after deleting the package it calls unbind
  (best-effort; default-deny covers any failure).
- **Settings → Apps panel** — a fifth action button; installed
  packages render as cards with a red "remove" affordance; tapping
  uninstalls through intentd (`app-removed` journaled) and refreshes.
- **The home grid self-refreshes** — the shell's loop wakes every 5 s,
  fetches the package list, and redraws only when the set actually
  changed (`package set changed — grid refreshed` journaled). An
  uninstalled app's tile disappears within seconds instead of living
  as a stale icon.

## Gate

`tools/uninstall-gate.sh`: boot (hello.oxp installed by the selftest) →
PIN unlock → Settings → Apps → tap Hello → require `app-removed
app=Hello` AND `perm-unbound app=Hello` → screendump → Back → Close →
wait for the grid refresh → tap the removed tile's old spot → require
that NO launch fires (absence asserted over 15 s) and that the refresh
journal exists. Artifact: `2026-09-06-uninstall.png`.

## Debug journey

The gate's first expectation was wrong in an instructive way: it
assumed a stale tile tap would be escalated and refused by intentd
(`app-not-packaged`). Reality: the shell's hit-test consults the LIVE
package list, so the stale tile was **inert** — the tap hit an empty
hit-zone and produced nothing at all. The visual staleness was the
only staleness, and the fix was the grid self-refresh (a genuine UX
improvement) rather than a gate relaxation: the final leg asserts the
inert behavior plus the refresh journal.

## Honest limits

- Running apps must be closed before uninstall (`app-is-running`
  refusal); a stop button on the panel is future UX.
- No uninstall confirmation step (v1: tap = gone; the store is
  re-installable).
- Grid refresh polls every 5 s while unlocked; an event-driven
  (intentd → shell) notification replaces polling in a later chunk.

## Verdict

**UNINSTALL GATE ALL GREEN** (2026-09-06): install → launch → grant →
relock → rotate → **uninstall through the UI** → grants die → grid
refreshes → dead tile is inert. The package lifecycle is closed.
