# Chunk 72 — the first hardware target builds: PinePhone Pro artifacts, host-verified

Date: 2026-10-05/06
Status: **DONE** (TARGET GATE ALL GREEN, board PASS 2026-10-06 01:29 UTC)

## What this chunk is

The hardware fleet's build-side bring-up: everything the PinePhone Pro
board would boot now EXISTS and is VERIFIED on the build host, so the
board itself only has to pass the electrical test (BRINGUP M1/M2).
Every artifact is produced by the executed nix pipeline — no stubs:

- **kernel-pinephone-pro**: the SAME pinned kernel.org 6.18.48 source
  as the qemu target (the verity/erofs/dm-crypt rootfs contract and the
  security posture are byte-identical policy), with the PinePhone Pro
  board block built in: RK3399 platform, 8250-DW console, eMMC
  (sdhci-arasan) + SD (dw_mmc-rockchip), Rockchip DRM + MIPI-DSI +
  XBD599 panel, Goodix touch, DWC3/FUSB302 USB-C, the EG25 modem bus
  (QMI + AT serial), RK818 PMIC/RTC. `kernel/fragments/pinephone-pro.config`
  is the .config source of truth; radios/camera/audio are deliberately
  NOT in this build — they land with their own hardware gates (M3+).
- **uboot-pinephone-pro**: mainline U-Boot 2024.10, pinephone-pro
  defconfig, with TF-A bl31 — built from the aarch64-multiplatform
  cross set (the pin writes rk3399 boot firmware for an aarch64-cc
  stdenv; see finding 2).
- **image-pinephone-pro**: the assembly — ox.itb (the FIT, SIGNED:
  sha256,rsa2048 dev key, signature on the configuration covering
  kernel+ramdisk+fdt, U-Boot-enforced via the control DTB key being
  `required = "conf"`), the raw boot triple, the keyed control DTB
  (extracted from U-Boot itself, public key injected), U-Boot stages,
  and the verified system slot — the SAME erofs+dm-verity rootfs the
  16-gate suite proves, re-verified host-side here.

## What the gate proves (all 11 green)

11/11 in one run: artifact set; triple hashes; arm64 boot Image magic;
dtb compatible (rockchip,rk3399 + pine64,pinephone-pro); FIT structure;
FIT signature present (Sign value); FIT-embedded kernel decompresses to
the source Image; control DTB carries the fit-dev public key marked
required=conf; u-boot.itb is a FIT + idbloader sane; **dm-verity slot
verification against digest.env's root hash**; everything fits its
BRINGUP.md partition.

## The eight reds on the way — each named, each fixed at the source

1. **kconfig repeated-question death**: the fragment pinned
   TYPEC_FUSB302 but not its dependency TYPEC_TCPM — the merge demoted
   FUSB302 and died on the repeat. Pin the dependency chain (and
   DRM_MIPI_DSI defensively). The 5600-question interactive session
   around it was NORMAL (defaults answered); only the repeat was fatal.
2. **TF-A built with the host x86 gcc** (`-mstrict-align` rejected):
   this pin's rk3399 boot firmware is written for the aarch64-multiplatform
   CROSS set (CROSS_COMPILE empty, meta.platforms aarch64) — take
   ubootPinebookPro from there, not from the x86 legacy set.
3. **TF-A license**: unfreeRedistributable (Rockchip blob) — scoped
   allowUnfree predicate for exactly that package; documented deviation
   (R-24), redistribution permitted.
4. **u-boot.bin not shipped** by the cross-set package → control DTB
   extracted from u-boot.itb instead.
5. **old dumpimage has no -n** → positional extraction; the control DTB
   is FIT image 6 (fdt-1: rockchip/rk3399-pinephone-pro).
6. **ITS syntax error**: the signed-configuration template lacked a
   semicolon after its closing brace.
7. **`required` lives in the control DTB, not the FIT**: mkimage -r
   marks the KEY required (required="conf" in the key node) — that is
   what makes U-Boot enforce; the gate asserts it there.
8. **ox.itb 65.3MB over the 64M boot partition** (defconfig-base
   kernel is huge) — AND a latent mislabel: the ITS said "gzip" while
   embedding raw bytes. Now actually gzipped into the FIT (U-Boot
   bootm decompresses natively), raw Image kept for the booti path,
   gate decompress-compares.

## Honest limits

- Structure-level proof: the gate cannot prove the panel lights up or
  the touch controller answers — that is M1 (electrical, needs the
  board). Addresses are U-Boot distro defaults pending M1 confirmation.
- u-boot.itb/idbloader are UNSIGNED: owner-key enrollment in U-Boot
  proper is M2 (the keyed control DTB is shipped for it).
- The rootfs ships the qemu radio modules (hwsim etc.): harmless on the
  board, but board radio drivers (RTL8822CS SDIO etc.) are M3+ scope.
- The gate's crypto verification is structural (signature presence +
  required enforcement + data-integrity by decompress-compare); the
  first full RSA verification runs in U-Boot on the board (M1).

## Verification chain

flake: kernel-pinephone-pro + uboot-pinephone-pro + image-pinephone-pro;
tools: target-pinephone-gate-run.sh (build+gate) → **PINEPHONE TARGET
GATE ALL GREEN**, board PASS 2026-10-06 01:29 UTC. Outputs gc-rooted.
