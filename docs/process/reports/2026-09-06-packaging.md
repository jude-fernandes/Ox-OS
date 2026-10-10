# .oxp packaging + oxpkg — the app set goes dynamic

Date: 2026-09-06
Status: **DONE — PKG GATE ALL GREEN** (install → refuse-broken →
list → manifest-spawn → exit → reap; verdict at bottom)

## Scope

Phase 3 chunk 9: apps stop being a compiled map in intentd and become
**packages**. An `.oxp` is a directory: `manifest.json` (name / bin /
version) + payload binary. intentd owns the package store
(`/data/ox/apps/<App>.oxp/`) and resolves spawns dynamically:

1. **Installed manifest** wins — `<store>/<App>.oxp/<bin>`.
2. **Built-in fallback** — the rootfs apps (Settings / Files /
   Terminal) stay launchable with nothing installed.
3. Everything else is refused by name, journaled.

New pieces:

- **oxpkg** — the package CLI (`install/remove/list/start`), a thin
  client over intentd's IPC ops; exit code + error string propagate.
- **intentd package ops** — install validates strictly (name
  alphanumeric, bin non-empty, no `/` or `..` in bin — traversal out
  of the package dir is structurally refused), copies the tree into
  the store with exec bits, and journals install/refuse/remove.
  Unit tests: five manifest rejection cases (missing name, bad name,
  bin traversal, bin path separator, non-JSON); resolve semantics
  (installed beats built-in; missing bin refused, never silently
  falls back).
- **ox-hello** — a real tiny app as the first package payload (ox-ui
  window, foreground wake-lock contract, 20 s demo lifetime,
  auto-exit so the gate can watch the full lifecycle).
- **Staged packages in the rootfs** — a valid `hello.oxp` and a
  deliberately broken one; the boot-time pkg-selftest REQUIRES the
  broken one to be refused (the negative leg is enforced, not
  optional).

## The find: noexec data vs installed code

First run: install ✓, broken-refused ✓, list ✓ — then
`spawn /data/ox/apps/Hello.oxp/ox-hello: Permission denied`. Root
cause: `/data` is deliberately mounted **noexec** (Phase-1 hardening:
data at rest never executes). The fix keeps BOTH postures — the
package store stays the noexec source of truth, and intentd stages a
fresh exec-capable copy onto the `/run` tmpfs (nosuid,nodev) at every
launch (`intent-stage` journaled, scratch recreated per start). This
is the same shape as Android's native-lib extraction, miniaturized:
code runs from scratch space, data never does.

## Gate

`tools/pkg-gate.sh` verifies the serial-log chain:
`intent-install app=Hello` → `intent-refused src=…/broken.oxp` →
`pkg-flow-ok` (selftest: install ok, broken refused, list ok) →
`intent-start app=Hello pid=…` → `intent-stage` → `hello-ready` →
screendump → `hello-exit` → `intent-exit app=Hello`. Artifact:
`2026-09-06-packaging.png`.

## Honest limits

- The shell grid is still a static four tiles — an installed app
  launches by name (`oxpkg start`, selftest) but doesn't get a tile
  yet. Dynamic grid tiles from the package list are the next UX
  chunk.
- No signatures yet: packages are validated for structure, not
  authenticity. Package signing (ed25519, same keytool as the payload
  manifest) is the security follow-up before any real distribution.
- Permissions arrays in manifests are parsed-but-not-enforced yet;
  they will bind into permstored at install time.
- Scratch copies are not content-addressed (per-start copy, fine at
  this scale).

## Verdict

**PKG GATE ALL GREEN** (2026-09-06): the full packaging lifecycle is
gate-verified — install a real package, refuse a broken one, list,
spawn by manifest through the noexec-safe staging path, watch it
draw, exit, and get reaped.
