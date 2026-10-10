# Fairphone 5 — Bring-Up Plan (T1 user-chained boot, primary target)

Status: **designed** (Phase 1). Hardware validation pending device fleet.

## Why this device

QCM6490, vendor-committed 8-year support, unlockable **and re-lockable** bootloader
with user-provided AVB keys (vendor-documented fastboot flow), strong mainline
trajectory. This is the only widely available device class where Tier-1 user-chained
verified boot is realistic at scale — hence primary target.

## Boot chain

| Stage | Component | Control |
|---|---|---|
| ROM + ABL | Qualcomm boot chain | vendor keys (fixed) |
| AVB | `vbmeta` verification | **user key** (enrolled via fastboot oem relock flow) |
| Payload | GKI kernel + dtbo + initramfs | signed under user AVB key |
| System | dm-verity erofs A/B slots | verified via vbmeta descriptors |

## Steps

1. Generate per-user AVB key (`avbtool extract_public_key`); enroll during unlock/
   relock per vendor process; record in provisioning log.
2. Build GKI-compatible kernel image matching the device's boot-image version;
   package as Android boot image v4 with our cmdline; sign with avbtool under user key.
3. A/B slots: system erofs+verity images flashed to `system_a/b`; metadata partition
   carries slot counters in RPMB-backed storage (SoC provides RPMB via eMMC/UFS).
4. Anti-rollback: vbmeta rollback index per slot; rotation supported by index bump.
5. CI acceptance mirrors PRD: ≤8s cold boot, tamper rejection, re-lock round-trip,
   key rotation without data loss (data keys are independent of AVB keys).

## Known gaps

- Camera pipeline tuning (libcamera IPA) — Phase 8 program.
- VoLTE/IMS depends on carrier + modem firmware; CSFB fallback first.
- Some sensors may require shim stage before mainline drivers land (HES shim-debt).
