# Package signatures — `.oxp` installs are authenticated

Date: 2026-09-06
Status: **DONE — PKG GATE ALL GREEN (with signature legs)** (verdict at
bottom)

## Scope

Phase 3 chunk 12: closes the packaging report's honesty gap — packages
are now **authenticated**, not just structurally validated.

- **Dev package keypair** (`tools/dev-keys/package.pem|.pub`,
  DEV ONLY — same trust tier as the payload's pinned dev key),
  generated with the repo's openssl-based keytool.
- **Build-time signing**: the rootfs derivation signs the staged
  hello.oxp manifest during buildPhase (`ox-keytool.py sign`) — and
  because **Ed25519 is deterministic**, the build stays
  bit-reproducible. The detached signature ships as
  `manifest.sig` inside the package.
- **Pinned trust**: the guest receives the public key at
  `/etc/ox/packages.pub.pem`; intentd verifies EVERY install against
  it with a **static aarch64 openssl** copied into the rootfs (the
  same primitive the host keytool uses — no hand-rolled crypto, no new
  Rust dependency chain).
- **Two refusal classes**, journaled distinctly: `missing-signature`
  and `bad-signature` (the diagnostic journal includes openssl's own
  stderr line — which is what diagnosed the fetch bug below).
- **The negative leg is enforced, not decorative**: a staged
  `evil.oxp` — structurally valid manifest (name "Evil", v9.9.9)
  carrying hello's signature — must be REFUSED, in both the boot
  selftest (acceptance fails the service) and the gate.

## Gate

`tools/pkg-gate.sh` (extended): `intent-sig-ok app=Hello` →
`intent-install app=Hello` → broken refused → **evil refused with
`reason=bad-signature`** → `pkg-flow-ok` → `intent-start` →
`hello-ready` → screendump → `hello-exit` → `intent-exit app=Hello`.
Artifact: `2026-09-06-signatures.png`.

## Debug journey — three quiet failures, one loud one

1. **CRLF kills nix builds.** Host-side python edit scripts converted
   `flake.nix`/`rootfs.nix` to CRLF; nix embeds that text into bash
   buildPhases and `$'\r': command not found` killed guest-daemons.
   All touched files converted back to LF; host-python edits on nix
   files are now followed by an LF scrub.
2. **The guest openssl wasn't static** — the pkgsCross musl `bin` is
   dynamically linked; the rootfs got the binary but not its
   `libcrypto` → musl loader: `EVP_MAC_free: symbol not found`. Fixed
   with the proven store-preserving closure copy (pipewire pattern).
3. **The closure copied the wrong output** — `closureInfo` over the
   package attr only captured the default `out`; the binary lives in
   the `bin` output. Root: `rootPaths = [ ...openssl-aarch64.bin ]`.
4. **The silent-failure bug**: the openssl closure-copy loop ran
   BEFORE the pipewire block that creates `$ROOTFS/nix/store` —
   `cp -r` into a nonexistent dir failed and `2>/dev/null || true`
   swallowed it (the exact pattern the charter warns about; here it
   bit because block order changed). Diagnosed by inspecting the
   built drv's buildPhase text, then the fresh output. `mkdir -p`
   added; every `|| true` in that block now has a comment.

## Honest limits

- The dev key is checked in — production requires a real key ceremony
  and key rotation story (release-phase concern; the verification
  path is complete and key-agnostic: swap the pinned PEM).
- Package revocation (a signed revocation list) is future work.
- The manifest permission arrays are still parse-not-enforce; binding
  them into permstored at install time is the next security chunk.

## Verdict

**PKG GATE ALL GREEN** (2026-09-06): signed install accepted after
signature verification against the pinned key; broken package refused
on structure; **evil package refused on signature**; lifecycle
(spawn → draw → exit → reap) unchanged and green.
