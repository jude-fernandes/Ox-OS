# Vendored AOSP AVB tooling (chunk 73)

`avbtool.py` — vendored verbatim from AOSP:

- source: https://android.googlesource.com/platform/external/avb
- branch: android-14.0.0_r1, commit 386fb90492db3bd6bc484a579bcde5b43a2a0292
  (2026-10-06)
- license: Apache-2.0 (see LICENSE)

Why this branch, not main: HEAD (c5066a96, post-quantum era) hard-
requires openssl ML-DSA support (3.5+) even on the RSA path — the
smoketest failed with "ML-DSA is not supported by the system openssl"
on the build host's openssl 3.0. The android-14 release is the
long-stable AVB v1.x implementation the FP5 ABL generation expects.

Why vendored: the pinned nixpkgs has no avbtool/mkbootimg packages, and
the AVB signature is the thing an Android-chain bootloader (Fairphone 5
ABL) verifies — it must be the REFERENCE implementation, not a
self-rolled crypto format checked only by itself. avbtool is both the
signer (`add_hash_footer`/`add_gvbmeta_image`) and an independent
verifier (`verify_image`), which the chunk-73 gate uses as the
cryptographic check. Smoketest: sign -> verify rc=0 -> tamper ->
verify rc!=0 (tools/avb-smoketest.py).

Runs on host python3 + openssl (no AOSP build system needed).
