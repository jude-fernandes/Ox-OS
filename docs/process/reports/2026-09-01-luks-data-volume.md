# LUKS2 data volume — unlock now proven in-guest; table load still blocked (R-23)

Date: 2026-09-01
Status: **major step, not green yet.** The full native LUKS2 unlock now
runs correctly in the real guest (digest validated end-to-end); the
remaining blocker is the guest kernel refusing to allocate *any* skcipher
for the dm-crypt table. Documented for the next session at the evidence
level.

## What this session proved in the real guest

```
ox-init: luks2: container detected on /dev/vdc, unlocking (24 bytes secret)
ox-init: luks2: iters=10000 saltlen=32 a_keysize=64 a_off=32768 a_size=258048
ox-init: luks2: slot 0 unlocked (iters=10000)
ox-init: luks2: dk_digest:8774af0e…
ox-init: luks2: hdr_digest:8774af0e…
ox-init: luks2: digest 0 validated
```

The entire unlock pipeline — pbkdf2 keyslot derivation, XTS keyslot-area
decrypt, LUKS1-style AF merge, volume-key digest check — matches what
cryptsetup formatted, inside the guest. The unlock had previously only been
host-validated.

## The one-byte bug that fixed the crypto

The dev key file carried a trailing newline: cryptsetup reads keyfile
bytes verbatim (25 bytes), ox-init strips `\n` (24 bytes) — two different
secrets, so the derived area key was garbage and every digest check failed.
`tools/build-payload.sh` now writes the key without a newline. Verified
independently: the fixed host pipeline (hashlib pbkdf2 + per-block XTS +
reference-checked AF merge) reproduces cryptsetup's dumped volume key
exactly (`tools/luks-variant-sweep.py`, ground truth
`cryptsetup luksDump --dump-volume-key`).

Two real defects were found in the debugging tooling along the way (both
mirrored the C correctly once fixed): an off-by-one in a Python AF-merge
loop and an asymmetric XTS pre/post mask in the first sweep. The C code
was right all along.

## The remaining blocker (R-23, sharply characterized)

The dm-crypt table load fails:

```
device-mapper: table: 252:0: crypt: Error allocating crypto tfm (-ENOENT)
ox-init: DM_TABLE_LOAD failed: ioctl rc=-1 errno=2
```

**The algorithms ARE registered.** A diagnostic dump of `/proc/crypto`
from ox-init (kept active on the dm-failure path) shows, in the failing
boot: `xts(aes)` twice (`xts-aes-neonbs` and `xts-aes-ce`), `ecb(aes)`,
`cbc(aes)`, `ctr(aes)` — all `selftest: passed`, `internal: no`. A probe
of four cipher specs (`aes-xts-plain64`, `aes-ecb`,
`capi:xts(aes)-plain64`, `aes-cbc-plain64`) — all ENOENT — and behavior is
identical with 512- and 4096-byte data sectors.

**Mask-drop experiment:** a kernel patch (kernel/dm-crypt-alloc-mask.patch,
currently DISABLED in kernel/kernel.nix) removing the
`CRYPTO_ALG_ALLOCATES_MEMORY` mask from dm-crypt's allocation changed the
failure from ENOENT to a guest panic: `crypto_lookup` returned a **NULL
algorithm** and dm-crypt dereferenced it (`crypt_ctr+0x538`, fault at
0x28). So the registered, self-tested `xts(aes)` is **invisible to the
lookup itself**, with or without the mask. This is a kernel-crypto
lookup/registration anomaly in the guest build, not a dm-crypt parameter
problem.

Rules out along the way: missing providers (`CRYPTO_AES_ARM64{_CE,_CE_BLK,
_BS}=y` now forced in kernel.nix — the BS provider was `=m`, unloadable
from the initramfs, and one non-existent symbol was silently ignored under
`ignoreConfigErrors`); driver absence (strings verified in the booted
Image); dm-crypt naming (6.18 requests exactly `xts(aes)`); FIPS gating
(`CONFIG_CRYPTO_FIPS=n`); sector-size paths.

## Next-session checklist

1. Live-debug the guest lookup: rebuild with `CONFIG_CRYPTO_SELFTESTS=y`
   (note: `mkForce` alone is silently dropped — it depends on
   `DEBUG_KERNEL`, which must be forced too) and read the `alg:` lines, or
   kprobe `crypto_alg_lookup`/`__crypto_alg_lookup`.
2. Diff the nixpkgs 6.18.48 kernel patches against vanilla for
   `crypto/api.c` / `crypto/algapi.c` changes to the lookup path.
3. Verify the skcipher frontend (`crypto_skcipher_type`) maskset behavior
   in 6.18.48 — the lookup must see `cra_name = "xts(aes)"` with flags
   `(SKCIPHER | TESTED)`.
4. Once allocation works, re-run `tools/receipts-persist-gate.sh` — the
   gate then proves receipts on an encrypted data volume across a power
   cycle (boot-1 receipt listed in boot 2).

## Honest scope

- The dev data volume is formatted by host cryptsetup (LUKS2, pbkdf2
  keyslot, xts) — standards-compliant; no custom dialect shipped.
- The dev passphrase is a documented constant (`ox-dev-data-passphrase-1`,
  R-22) — dev only.
- Until the table loads, the guest falls back to the unencrypted plain
  mount; receipts then fail loudly (read-only rootfs) rather than silently
  landing somewhere insecure — gate-verified behavior.
