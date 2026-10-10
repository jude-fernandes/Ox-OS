# Chunk 77 — guest-side A/B slot reader (M2 groundwork)

Date: 2026-10-09
Status: **GREEN** — `target-slotboot-gate` PASS (see board).

## What ships

The guest can now boot a flashed A/B layout end-to-end: stage-1 reads
the slot metadata block, picks the active slot, applies the rollback
rule, builds the in-slot dm-verity root, unlocks the LUKS data
partition, and hands off to stage-2, which confirms the boot back into
the metadata.

- `initramfs/ox-init.c` — `slot_boot()`: metadata read (wait-for-path +
  mknod-from-sysfs fallback), integrity check, rollback rule
  (attempts >= 3 -> other slot), attempts pre-count, dm-linear `oxhash`
  over the system slot partition at the in-slot tree offset
  (2944 MiB), dm-verity `oxsys` from the slot's own root hash,
  `luks_try_unlock` on the data partition, mount + handoff.
- `initramfs/ox-slotmeta.h` / `tools/ox-slotmeta.py` — metadata format
  v1 ("OXSB", 136 bytes): active slot, attempts, per-slot boot counts,
  root hashes, dm-verity data blocks, sha256 integrity.
- `rust/crates/oxctl` — `slot-confirm` subcommand: verifies metadata
  integrity, refuses a double confirm (attempts==0), clears the
  attempt counter, bumps the boot count, journals
  `OXMILESTONE name=slot-confirmed slot=N count=M`.
- `system/s6-rc-source/slot-confirm` — longrun (see R-21 note) that
  confirms once and idles.
- `targets/pinephone-pro/ox-flash.sh` — six-partition GPT
  (ox-boot-a/b 64M, ox-system-a/b 3G, ox-metadata 16M, ox-data 512M
  LUKS2), initial metadata written active=a.
- `targets/pinephone-pro/ox-update.sh` — writes slot b (system +
  in-slot tree), flips metadata active=b.
- `tools/target-slotboot-gate.sh` — the gate: offline fleet build
  proof, flash, BOOT 1 (count + confirm), update flip, BOOT 2
  (rollback to a after exhausted attempts on b), metadata consistency.

## Gate-verified behavior

```
name=slot-boot slot=0 attempts=1 rollback=0 count_a=0 count_b=0
name=slot-root slot=0 rollback=0
name=slot-confirmed slot=0 count=1
name=slot-rollback from=1 attempts=3
name=slot-boot slot=0 rollback=1
name=slot-confirmed slot=0 count=2
```

## Defects found and fixed on the way (all root-caused, no fakes)

1. **slot_part NUL-in-string** — `snprintf("%s%c%d")` with a 0
   separator embedded a literal NUL: `/dev/vda6` truncated to
   `/dev/vda`; everything downstream mapped the whole disk.
2. **oxhash geometry on the wrong partition** — the hash tree lives in
   the system slot partition; the code sized/backed the dm-linear from
   the LUKS data partition (512M < tree offset).
3. **sysfs layout** — partition attributes nest:
   `/sys/block/vda/vda3/size`, flat `/sys/class/block/<part>/size` as
   the fallback.
4. **Watcher SIGTTOU freeze** — jobs run by the queue watcher behind a
   foreign foreground pty group froze QEMU in state `T` before its
   first serial byte (`-nographic` stdio chardev touches the terminal);
   empty "serial logs" in three gate reds were this. Watcher now runs
   jobs via `setsid` + `</dev/null`; slotboot boots use
   `-serial file:` (no fd-0 dependency at all).
5. **dm-crypt ENOENT retry** — the first `aes-xts` table load can race
   cipher self-test completion; retried (60x250ms) instead of dropping
   the data volume. R-23 itself (registered-but-unallocatable skcipher
   in the TCG guest) remains open and untouched.
6. **dm-verity digest/salt swap** — the table is
   `<algorithm> <digest> <salt>` (ctr argv[8]/argv[9]); both spec
   constructions passed salt first. Unnoticed for months because the
   qemu payload defaults to `OX_SKIP_VERITY=1` (R-19) — the slot path
   enforces verity unconditionally and was the first to exercise it.
   Host `veritysetup` on the flashed layout proves the corrected
   guest chain (tools/verity-slice-diag.sh).
7. **slot-confirm under R-21** — s6-rc live-state does not come up in
   the TCG guest (known R-21); the fallback starts longruns only, so a
   oneshot never fires. slot-confirm is a longrun that confirms once
   and idles; `oxctl` refuses a second confirm.
8. **run script shebang** — s6 executes ./run directly; a shebang-less
   script fails with ENOEXEC ("Exec format error").

## Open / unchanged

- **R-23**: dm-crypt skcipher lookup returns ENOENT in the TCG guest
  even for registered, selftest-passed `xts(aes)` (see
  reports/2026-09-01-luks-data-volume.md). The guest continues without
  the encrypted data volume (loud, by design). The slot gate's
  assertions do not depend on /data.
- **R-19** (skip-verity default on the virtual target) and **R-21**
  (s6-rc fallback) are unchanged; the digest/salt fix also repairs the
  hardware-path (non-slot) verity table for when R-19 is lifted.
