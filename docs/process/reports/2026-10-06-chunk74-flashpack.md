# Chunk 74 — flash-ready: the boards can be flashed and enrolled from these artifacts

Date: 2026-10-06
Status: **DONE** (FLASHPACK TARGET GATE ALL GREEN, board PASS 21:18 UTC)

## What this chunk is

The last host-side step of M1-prep (BRINGUP): the verified artifacts
from chunks 72/73 become the things the boards physically consume, and
the enrollment flow gets its tooling.

- **targets/pinephone-pro/ox-flash.sh** — the PinePhone Pro flash
  script: writes idbloader at the bootrom's sector-64 load point (the
  BRINGUP table's "0x0 region"; sector 64 keeps the GPT intact —
  idbloader ~190KB ends before u-boot.itb at 0x80000), u-boot.itb at
  0x80000, then the five BRINGUP GPT partitions (ox-boot-a/b 64MiB,
  ox-system-a/b 3GiB, ox-metadata 16MiB, ox-data LUKS2), drops ox.itb
  into boot-a and system.img into system-a, and LUKS2-formats the data
  partition under the payload dev key (R-22) when given the partition
  device. Device-adaptive: the script partitions whatever it is pointed
  at; "data = rest" sizing is provisioning.
- **tools/ox-provision.py** — the owner-key enrollment step: extracts
  the owner AVB public key with the vendored reference avbtool,
  computes the pkmd (sha256 — the value enrolled at re-lock), REFUSES
  the dev key as owner (enrolling the dev identity would re-lock the
  device to development), and writes the provisioning log BRINGUP
  step 1 requires (owner pkmd, rollback baseline, artifact hashes).
- **tools/target-flashpack-gate.sh** — proves both HOST-SIDE: ox-flash
  runs against a loop-backed sparse image (flash → detach → re-attach
  -P so partitions scan), then the gate verifies device state by
  extraction: idbloader byte-identical at sector 64, u-boot.itb at
  0x80000, GPT names/sizes/spans, boot-a == ox.itb and system-a ==
  system.img byte-for-byte, and the LUKS2 data partition opening under
  the dev key. Then the FP5 provisioning round-trip: test owner key →
  log written, owner pkmd ≠ dev pkmd, rollback baseline 0, stable on
  re-run.

## The six reds on the way — each named

1. image-pinephone-pro did not ship data.img.key (the flash input the
   LUKS step needs) → the derivation now carries it.
2. loop partition devices only re-scan at ATTACH with -P → the gate's
   flash flow is attach-bare → flash → detach → re-attach -P.
3. sgdisk -c takes `num:name` colon form; the two-argument form made
   sgdisk treat the partition NAME as a file.
4-5. the gate's own dd extractions mixed block-units with byte counts
     (idbloader, boot-a, system-a) → uniform `dd | head -c byte-length`.
6. the GPT size check read sgdisk's END-SECTOR column as a KiB size;
   it now asserts the start/end sectors directly (32768–163839).
Plus one path slip: ox-provision writes the extracted owner key under
--out (the gate looked in the parent).

## Honest limits

- Loop-level proof, not board-level: sector 64 for idbloader follows
  the rk3399 bootrom convention; M1 confirms it on the device (and
  whether the vendor bootloader chain on FP5 accepts the vbmeta).
- The FP5 provisioning log is a document, not yet counters: RPMB-backed
  rollback storage is M2 on-device.
- The updater writing slot _b is M2 (the script leaves _b empty).

## Verification chain

tools/target-flashpack-gate-run.sh (builds both image sets cached from
chunks 72/73, then gates) → **FLASHPACK TARGET GATE ALL GREEN**
(board PASS 2026-10-06 21:18 UTC). Outputs gc-rooted.
