# Chunk 76 — the A/B slot updater: write, verify, count, preserve

Date: 2026-10-08
Status: **DONE** (SLOT-UPDATE TARGET GATE ALL GREEN, board PASS 04:28 UTC)

## What this chunk is

The first M2 groundwork: slot _b is no longer an empty partition —
there is a proven write path into it, and a metadata format that
records which slot is active.

- **tools/ox-slotmeta.py** — the slot-metadata format for the
  ox-metadata partition (4KiB, magic OXSB, versioned): active slot,
  boot_attempts (unconfirmed-boot counter), per-slot boot counts,
  per-slot dm-verity root hashes, and a sha256 integrity block over
  the whole record. Tamper detection proven (unit selftest + on-device
  bit-flip in the gate). This is what the guest ox-init will read to
  pick the slot and confirm boots (the next M2 step).
- **targets/pinephone-pro/ox-update.sh** — the host write path:
  preflight dm-verity verification of the INCOMING system.img (never
  install an unverifiable slot), write ox.itb + system.img into slot
  _b, read back byte-for-byte, flip metadata to active=b with
  boot_attempts=0 and both root hashes recorded. Slot _a is never
  touched — the fallback is preserved by construction and proven by
  the gate (before/after snapshot compare).
- **tools/target-update-gate.sh** — section A: the fleet offline
  capability proof (all six outputs build `--offline` post-GC).
  Section B: the full lifecycle on a loop device — flash → snapshot
  slot a → update → readbacks → metadata assertions → idempotent
  second update → tampered-metadata rejection.

## The reds on the way — each named, each fixed at source

1. **ox-flash.sh never created a boot-b partition** (five BRINGUP
   partitions instead of six — the chunk-74 gate asserted the wrong
   set too). Layout fixed to the real six; flashpack gate updated
   (six names, system-a extraction moved to the shifted 144MiB
   offset); update gate indices renumbered.
2. **loop devices carry no /dev/disk/by-partlabel** (real-hardware
   udev feature) — the updater resolves via the GPT itself (sgdisk
   index → ${DEV}p<index>).
3. ox-slotmeta's argparse rejected its own --write selector →
   parse_known_args.
4. Section A's offline proof found the truth left by the storage
   cleanup: output GC-roots do NOT protect build-time inputs, so the
   post-GC offline build rebuilt rustc + kernel-qemu + the whole musl
   cross-stdenv from source (~13h). It passed — offline capability
   holds even from a gutted store — and the permanent fix (rooting
   DRV closures in gc-keep-current) makes the next GC a no-op for
   build inputs.

## Honest limits

- Host-side lifecycle: the guest side (ox-init reading the metadata,
  choosing the slot, confirming boots by counter, rolling back on
  exhausted attempts) is the next M2 step — this chunk proves the
  write path and the format it will consume.
- The updater writes what it is given; signature-level slot
  verification (AVB on the boot slot) rides the chunk-73/75 vbmeta
  chain and is asserted by their gates.

## Verification chain

tools/target-update-gate-run.sh (builds image-pinephone-pro cached,
offline-proof, lifecycle) → **SLOT-UPDATE TARGET GATE ALL GREEN**
(board PASS 2026-10-08 04:28 UTC). Outputs gc-rooted.
