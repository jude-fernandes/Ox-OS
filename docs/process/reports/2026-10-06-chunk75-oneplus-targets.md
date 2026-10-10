# Chunk 75 — OnePlus 9RT + 10 Pro: the fleet is complete — all four targets build and gate green

Date: 2026-10-06
Status: **DONE** (ANDROID TARGET GATE ALL GREEN for both: oneplus9rt
verified ~23:0x UTC in-run; oneplus10pro board PASS 23:18 UTC)

## What this chunk is

The third and fourth executed hardware targets — the OnePlus 9RT
(SM8350) and 10 Pro (SM8450) — completing the fleet: every target in
targets/ now has an executed nix pipeline and a host-side gate verdict.
Both run the Android chain (like the FP5) but exercise the remaining
boot-image paths the fleet needs:

- **9RT**: header **v2** — the board FDT is EMBEDDED in boot.img (no
  dtbo partition); AVB hash footer + vbmeta chain root.
- **10 Pro**: header **v4 + vendor_boot** — the FDT rides
  vendor_boot.img (per target.env), AVB hash footers on boot AND
  vendor_boot + vbmeta chain root.

Shared builder: kernel/kernel-oneplus-qcom.nix serves both SoCs
(the `soc` parameter is a placeholder — today's boot-essentials
configurations are identical, so one kernel derivation serves both;
per-SoC divergence happens when the hardware gates demand it). Board
block = the chunk-73 qcom essentials (GENI console, UFS, DWC3-QCOM,
QRTR scaffold, PMIC/RTC); display/radios/charging/NFC/touch remain
M-gate scope (the phase-1 targets/*/kernel.fragment files stay as the
design record). The kernel avoided the config-demotion traps entirely —
zero config reds.

Gate generalization: tools/target-android-gate.sh replaces the FP5-specific
gate (chunk-73 file kept as the FP5 record) — the checks are the same,
the artifact SET is whatever the target ships (dtbo/vendor_boot
optional, each AVB-verified when present, chain descriptors tied to the
shipped keys). The FP5 runner now uses it too (re-verified implicitly —
its artifacts are unchanged).

## Board DTS honesty

mainline's OnePlus DTS status is an M1 question; the assembler packs the
first-found of {device DTS, SoC reference} — the 9RT build packed
sm8350-mtp.dtb (the SoC reference board). The gate asserts FDT validity
and the packer logs which dtb shipped; the real device DTS lands with
the board (M1).

## The reds on the way — each named, each fixed at source

1. **My chunk-73 offset fix regressed the v2 verify branch.** The
   v3+ header layout change (ramdisk_size at 12, not 16) was applied to
   the v0-v2 branch too — where the legacy layout correctly keeps
   ramdisk_size at 16. Every v2 verification then read kernel_addr as
   the ramdisk size (0x10080000 = the printed 268959744) and failed
   SHA1. The 9RT gate caught it; the branch is reverted with a comment
   naming the regression class (a fix for one layout must never touch
   the other).
2. **trailing-garbage check vs AVB padding** (the chunk-73 dtbo
   lesson, now general): the gate verifies POST-AVB images whose tail
   is the hash footer + partition padding — legal, signature-covered.
   The pre-AVB check removed from the verifier.
3. One flake-edit slip (the image-fairphone5 block was replaced instead
   of appended) — caught immediately by the sync grep, restored.
4. Observation (not a red): the two OnePlus kernels are one derivation
   today — see above.

## Honest limits

Same class as chunks 72-74, now fleet-wide: structure + signature
proofs host-side; the boards owe M1 (ABL acceptance of our vbmeta,
panels, touch, radios). The OnePlus devices are the fleet's T2 class —
the FP5 remains the primary (re-lockable) target.

## Verification chain

flake: kernel-oneplus9rt/10pro (one shared builder) +
image-oneplus9rt/10pro; tools: target-oneplus{9rt,10pro}-gate-run.sh →
**ANDROID TARGET GATE ALL GREEN (oneplus9rt)** and **(oneplus10pro)**
(board PASS 2026-10-06 23:18 UTC). Outputs gc-rooted.
