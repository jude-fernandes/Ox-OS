# Chunk 70 — permstored write-path ACL: grants are writable by the system only

Date: 2026-10-05
Status: CLOSED — ACL gate (6 sides) and notify gate ALL PASS

## The hole — the one that would have made everything else theater

Chunks 58-68 hardened every READ and every lifecycle mutation, but the
permission store's WRITE path was open: `permstored set` (and bind/
unbind) answered any caller. An app could have issued
`set {"app":"itself","permission":"contacts.read","mode":"grant"}` and
self-granted — making every downstream consult check decorative. The
grant model's premise ("grants are the user's, expressed through the
panel") had no enforcement at the store.

## The fix

`set`/`bind`/`unbind` require a system writer: **ox-settings** (the
grants panel — where the user expresses grants), **oxctl** (dev and
selftest seeds), **ox-intentd** (install-time bind, uninstall-time
unbind). `get`/`list` stay open — the daemon intermediaries consult,
read-only, fail-closed as before. Refusals journal
`perm-acl-refused op=… caller=…`. The identity is the kernel-verified
peer comm (chunk 68's plumbing); the store itself gained the same ACL
shape as intentd (chunk 69) and oxcom (chunk 60).

## The in-guest proof — identity is the comm, demonstrated

acl-selftest leg 7 copies the very oxctl binary to another name and
calls the same `set`:

- `/tmp/not-oxctl permstored set …` → **refused**
  (`acl: set requires a system writer`), journaled
  `perm-acl-refused op=set caller=not-oxctl`
- the REAL `/usr/bin/oxctl permstored set …` → **accepted** (positive
  control, same store state)

Same code, different file name, different kernel comm, different
answer — the permission write path is comm-gated end to end.

## Verification

- workspace-test ALL GREEN
- ACL gate ALL PASS — six sides now: SYSTEM, NORMAL, INPUT, SANDBOX,
  IDENTITY, **WRITE**
- notify gate ALL PASS — the ox-settings panel write (the legitimate
  user grant path) unbroken

## The permission architecture, post-chunks 43/49/55/60/61/62/68/69/70

- reads: fail-closed consults, caller = kernel comm (68)
- writes: system writers only, kernel-identified, journaled (70)
- lifecycle: system clients only, reserved bins refused (69)
- input: process-scoped (61); screen pixels: granted + sandboxed (62/65)
- the lock secret: hashed, throttled, duress-separated (49/55)
- every boundary refusal journals evidence with the caller named
