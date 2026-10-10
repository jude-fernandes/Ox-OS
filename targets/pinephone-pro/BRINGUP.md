# PinePhone Pro — Bring-Up Plan (T1 user-chained boot)

Status: **designed** (Phase 1). Hardware validation pending device fleet.

## Boot chain

| Stage | Component | Control |
|---|---|---|
| ROM | RK3399 bootrom | loads from SPI/eMMC, verifies nothing by default |
| TPL/SPL | U-Boot TPL+SPL (mainline) | ours |
| U-Boot proper | mainline U-Boot with FIT verification | ours |
| Payload | ox FIT image: kernel + dtb + cmdline | **user-key verified** |
| System | dm-verity erofs slot | verified via payload signature |

## Steps

1. Build U-Boot mainline `pinephone-pro-rk3399_defconfig` with
   `CONFIG_FIT_SIGNATURE=y`; inject the owner public key via control DTB
   (`/signature/key-dev`); enable required=fit.
2. Key enrollment: owner runs `ox key enroll --target pinephone-pro` which embeds
   their ed25519 pubkey into U-Boot env/DTB at provisioning time (first flash).
   Rotation = re-flash of signed U-Boot with new key + counter bump.
3. `ox build image pinephone-pro` produces: `u-boot.itb`, `boot FIT`, system A/B
   images. Flash layout:

| Offset | Part | Size |
|---|---|---|
| 0x0 | idbloader (TPL+SPL) | 512K |
| 0x80000 | u-boot.itb | 1M |
| 0x180000 | reserved | — |
| — | boot_a / boot_b | 64M each |
| — | system_a / system_b | 3G each |
| — | metadata | 16M |
| — | data (LUKS2) | rest |

4. Verified-boot guarantee on this device is **Tier 1**: every stage after the maskrom
   is under user keys; anti-rollback via metadata counters (RPMB not available on this
   SoC's eMMC path → fallback: GPT metadata partition with monotonic file + optional
   RPMB where eMMC supports; documented deviation).
5. CI acceptance: cold boot ≤8s measured on fleet unit; tamper test flips a byte in
   FIT → must refuse boot and fall to recovery.

## Known gaps

- Modem (Quectel EG25) works over USB QMI; VoLTE via carrier-dependent firmware.
- Camera sensors (OV8858 etc.) need libcamera tuning files — Phase 8.
- eMMC RPMB availability varies per unit — detect + degrade honestly.
