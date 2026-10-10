# Chunk 65 — the screendump destination sandbox

Date: 2026-10-01
Status: code landed, workspace-test ALL GREEN; acl + oxcom-pm gates queued

## The hole

Chunk 62 permission-gated the screendump op (a `screen.read` grant,
kernel-verified caller identity) — but the op then wrote the PPM to
**whatever path the caller named**, as root:

```rust
let Some(path) = payload.get("path")...;
std::fs::write(path, bytes)   // arbitrary root-owned file write
```

A `screen.read` grant is supposed to buy *pixels*. Without a destination
sandbox it also bought a write-anywhere primitive: a granted app could
truncate `/data/ox/permstore.journal` (corrupting the permission store),
overwrite another daemon's files, or plant files anywhere root can reach.
Documented as a residual in chunk 62; this chunk closes it.

## The rule

Exactly one destination shape is legal: **a flat filename directly inside
`/data/ox/artifacts/`** — the one directory every selftest and gate
artifact lives in (verified: all six callers use exactly that shape).

- `dump_path_ok(path)` (pure, unit-tested): strips the prefix, then
  rejects empty/`.`/`..`, any `/` or `\` in the remainder (a subdirectory
  would allow a component symlink to redirect the whole tail), and any
  non-canonical form (relative paths, missing prefix).
- **`O_NOFOLLOW` on the final component at open time**: the string check
  cannot see what a planted symlink resolves to; the kernel refuses it.
  The open failure is journaled (`reason=open`) and refused.
- Refusals journal `acl-refused op=screendump app=<comm>
  reason=outside-artifacts path=<path>` — the same evidence class as the
  chunk-62 permission refusal.
- The write is `write_all` + `sync_all` (the previous `fs::write` had no
  durability either — artifacts are pulled from the data image by gates
  after a kill, so the sync matters).

## Proof in the guest

`acl-selftest` leg 5 (the unprivileged-oxctl harness from chunks 60-62):

1. grants itself `screen.read` (the same grant the dumping selftests use),
2. aims at `/data/ox/permstore.journal` → **refused**
   (`acl-sandbox-refused op=screendump`, and oxcom journals the refusal
   with `reason=outside-artifacts`),
3. positive control: `/data/ox/artifacts/acl-sandbox-ok.ppm` → **lands**
   (`acl-sandbox-allowed op=screendump`).

ACL gate extended with three waits (refusal + oxcom-side journal + positive
control). `oxcom-pm` gate re-run as the granted-path regression (its
post-resume dump is exactly the legal shape).

## Verification status

- workspace-test **ALL GREEN** (new sandbox unit test: legal shape, prefix
  escapes, traversal, subdirectory, degenerate forms).
- ACL gate + oxcom-pm gate queued. Verdicts appended below.

## Verdicts (first run, 2026-10-01 ~20:44 UTC)

- ACL GATE: **ALL GREEN** — new SANDBOX side green: "granted screendump
  confined to /data/ox/artifacts/, refusal journaled"
- OXCOM-PM GATE: **ALL GREEN** — granted-path regression (post-resume
  dump is the legal shape)

Serial evidence (both sides of the wire):
- `DBG-ACL-SANDBOX {"op":"screendump","error":"screendump: path outside
  /data/ox/artifacts/"}` + `acl-sandbox-refused op=screendump` (+ the
  oxcom-side `acl-refused ... reason=outside-artifacts` journal the gate
  waited for)
- `compositor-screendump path=/data/ox/artifacts/acl-sandbox-ok.ppm
  w=1280 h=800` + `acl-sandbox-allowed op=screendump`

Status: **CLOSED.** Chunk-62's residual is gone; the screen.read grant now
buys exactly pixels into one directory and nothing else.
