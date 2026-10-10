# oneplus9rt-sm8350 — Ox OS Bring-Up (Android bootloader, T3 unlocked-only)

Status: **scaffolded**. No hardware claim until milestone M4 is signed off.

## Bootloader facts to confirm on real unit

- [ ] `fastboot flashing unlock` works (document wait period / account gates)
- [ ] Accepts our header version (target.env OX_BOOT_HEADER_VERSION); fall
      back to v2 if ABL rejects, or v3/v4 if it demands them
- [ ] `fastboot oem` / partition layout (`boot[_a]`, `vendor_boot[_a]?`, dtbo)
- [ ] Recovery-slot trick possible (Ox in recovery slot = reversible demo install)

## Milestones (each requires serial/USB evidence committed here)

| # | Milestone | Evidence |
|---|---|---|
| M1 | Kernel boots headless from boot.img; initramfs reaches stage2 shell | console dump |
| M2 | Display panel driven by mainline DSI driver; framebuffer console visible | photo + dmesg |
| M3 | Touch input via mainline driver reaches userspace | evtest log |
| M4 | Verified-boot gate live (manifest checked before mount) | attack-suite run on device |
| M5 | Modem: SIM detect, SMS, data (QRTR + mss remoteproc) | mmcli output |
| M6 | Battery/fuel-gauge, buttons, sensors | sysfs/iio evidence |
| M7 | Camera pipeline (libcamera IPA) — Phase 8 scope | defer |

## SoC notes (Qualcomm SM8350 (Snapdragon 888))

- Kernel fragment enables ARCH_QCOM + this SoC's DTBs; see kernel.fragment.
- Firmware blobs: enumerate in firmware.manifest (modem, WiFi/BT, DSP) with
  hashes; extract from stock OTA per policy doc.
- GPU: Freedreno path expected; confirm a6xx/a7xx support level for this
  SKU before promising UI acceleration.

## Honest constraints

- Until M5 the device is a headless Linux board with a phone battery.
- Real-world risk register entry R-25 covers unverified ABL acceptance of
  our generated images; first flash attempt happens in recovery slot.
