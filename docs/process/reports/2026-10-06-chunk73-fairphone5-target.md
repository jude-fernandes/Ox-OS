# Chunk 73 — Fairphone 5: the Android chain builds — AVB-signed boot artifacts, host-verified

Date: 2026-10-06
Status: **DONE** (FAIRPHONE TARGET GATE ALL GREEN, board PASS 20:28 UTC)

## What this chunk is

The second executed hardware target — and the first on the **Android
boot chain** (the FP5 is the BRINGUP primary: re-lockable bootloader
with user AVB keys). Everything the board would flash now exists and
verifies on the build host; the board owes M1 (unlock/relock with the
user key per the vendor fastboot flow):

- **kernel-fairphone5**: same pinned 6.18.48 mainline (pmOS path — the
  boot-image v4 container is GKI-shaped; GKI conformance itself is M1),
  byte-identical storage/security policy, QCM6490 board block: GENI
  console (ttyMSM0), UFS storage, DWC3-QCOM USB, QRTR modem transport
  scaffold, PMIC/RTC. Display deliberately OUT of this build (finding
  4); radios/camera land with their own hardware gates (M3+).
- **image-fairphone5** assembly: boot.img (Android boot image v4,
  gzipped kernel + initramfs), dtbo.img (dt_table carrying the board
  FDT), vbmeta.img (the chain root: boot + dtbo descriptors), and
  **avb-pkmd.bin = sha256(boot public key)** — the exact value the user
  enrolls at re-lock. All three images signed under the dev AVB key
  (SHA256_RSA4096) with the VENDORED REFERENCE tool.

## The tooling decision: vendored reference avbtool

The pinned nixpkgs has no avbtool. The AVB signature is what the
device's bootloader verifies, so it must be the REFERENCE
implementation, not a self-rolled format checked only by itself.
`tools/aosp/avbtool.py` is vendored verbatim from AOSP
android-14.0.0_r1 (386fb904, Apache-2.0, provenance in
tools/aosp/README.md). Proven by smoketest (tools/avb-smoketest.py):
sign → verify rc=0 → one-byte tamper → verify rc=1. avbtool is both
signer and independent verifier; the gate uses `verify_image` three
times. (main-branch HEAD was rejected: it hard-requires openssl 3.5
ML-DSA support even on the RSA path — the smoketest caught it.)

## What the gate proves (11 green)

Artifact set; boot.img re-parses (house verifier, header v4, checksums);
dtbo.img re-parses (magic, entries, FDT blobs, AVB padding tolerated);
**AVB verify_image passes for boot.img, dtbo.img AND vbmeta.img** with
the chain descriptors tied to the shipped public keys; avb-pkmd
recomputes; vbmeta rollback index 0 (dev baseline); **dm-verity slot
verification** (the 16-gate-proven rootfs).

## The nine reds on the way — each named, each fixed at source

1. avbtool main-branch HEAD requires openssl ML-DSA (3.5+) even for
   RSA → pinned android-14.0.0_r1 instead.
2. `verify_image --key` wants a PEM (openssl-fed), not the raw
   extracted key — the .pub file is the enrollment artifact, not a
   verifier input.
3. Hash-descriptor verification resolves `<dir>/<partition_name>.<ext>`
   — the signed file must literally be named boot.img.
4. FP5 kernel config, two =m-capped demotions (the documented
   cfg80211 class from kernel/kernel.nix): MSM DRM's select closure
   and TYPEC_QCOM_PMIC. Display is deferred to M1 (per-target DRM
   module closure, validated against the real panel); the boot
   contract is the GENI serial console.
5. ox-mkdtbo required --dtb even in --verify mode.
6. dtbo packer declared entries_offset=64 while writing entries at 32 —
   the verifier read the blob's FDT magic as an entry size.
7. ox-mkbootimg v4 verify read ramdisk_size at offset 16 (os_version)
   instead of 12 — packing was correct, verification lied.
8. dtbo total_size vs file size: AVB hash footers pad to the partition
   size — trailing padding is legal (the footer's signature covers it).
9. Gate read the vbmeta rollback index at offset 48 (signature_offset)
   instead of 112.

## Honest limits

- Structure + signature level: the gate proves the chain the ABL will
  enforce, cryptographically, with the reference tool. It cannot prove
  the FP5 ABL accepts OUR vbmeta (that is M1: unlock → flash → re-lock
  round-trip on the device), nor that the panel lights (M1) or the
  radio registers (M3+).
- Mainline kernel, not GKI android-common: the container is v4-shaped;
  true GKI conformance is an M1 question with the device's bootloader
  version in hand.
- Dev AVB key ships in-tree until owner enrollment (M2); rollback
  index rotation is M2.

## Verification chain

flake: kernel-fairphone5 + image-fairphone5;
tools: target-fairphone5-gate-run.sh (build+gate) → **FAIRPHONE TARGET
GATE ALL GREEN** (11 checks, board PASS 2026-10-06 20:28 UTC). Kernel
cross-build 2h45m; outputs gc-rooted.
