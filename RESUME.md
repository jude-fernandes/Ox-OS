# RESUME.md — read this first (every session, human or agent)

Ox OS is a from-scratch, privacy-enforcing Linux mobile OS. This file is
the entry point: it exists so any future session — especially a small,
credit-limited one — can be useful within minutes instead of re-reading
40 reports.

## Where things stand (2026-10-10)

**Proven by boot gates in QEMU (all green on the board):**
- Boot → dm-verity rootfs → LUKS data probe → s6 service stack →
  selftests (phase 1, ~70 chunks)
- 4 hardware targets build + verify end-to-end: PinePhone Pro (U-Boot
  FIT signed), Fairphone 5 (Android boot v4 + dtbo + AVB), OnePlus 9RT
  (v2), OnePlus 10 Pro (v4 + vendor_boot) — `tools/target-android-gate.sh`
- Flash-pack + owner-key enrollment — `tools/target-flashpack-gate.sh`
- A/B slot lifecycle — `tools/target-slotboot-gate.sh` (chunk 77):
  stage-1 reads the metadata block, picks the active slot, rolls back
  on exhausted attempts, mounts the slot through its own verity tree;
  `oxctl slot-confirm` clears the counter and bumps the boot count.

**NOT done:** nothing has booted on real hardware (QEMU only);
R-19/R-21/R-23 bypasses below; no UI stack beyond service level.

## The machine (WSL2 on the Windows host)

- Build tree: `/root/oxbuild` (a nix flake). Windows mirror:
  `C:\Users\rawc1\Desktop\Opencode\Ox OS\ox` — edit there, sync with:
  `tar czf /tmp/oxsync.tgz -C "<repo-root>" <paths> | wsl -u root bash -c "cat > /tmp/x.tgz && tar xzf /tmp/x.tgz -C /root/oxbuild"`
  (archive paths are relative to the repo root — no `ox/` prefix!)
- Queue watcher: usually already running (`ps -eo pid,cmd | grep watcher`).
  Start if missing: background `wsl -u root bash -c "exec bash /root/oxbuild/queue/watcher.sh"`.
  WSL bounces daily ~12:30 UTC — relaunch after each bounce.
- Queue a job: append the command line to `/root/oxbuild/queue/queue.txt`
  (verbatim; the watcher runs it). Verdict: `tail /root/oxbuild/queue/board.txt`;
  job log: `/root/oxbuild/queue/status/<ts>-<job>.log`.

## wsl.exe gotchas (these cost whole sessions — read before debugging)

- Never use `$VAR`, `$(...)`, or `$?` inside `wsl bash -c "..."` —
  Windows eats them. Write scripts to the Windows tree and sync instead.
- `MSYS_NO_PATHCONV=1` for POSIX paths (/nix, /root) in wsl command args.
- QEMU under the watcher must not touch the controlling terminal:
  watcher runs jobs `setsid ... </dev/null`; boots use `-serial file:`.
  A pty + termios touch = SIGTTOU = QEMU frozen in state T = empty log.
- Board timestamps are UTC; local clock is +1h.

## The discipline (non-negotiable)

Every chunk ends with OXMILESTONE assertions grepped from real boots,
on the board. No fake progress: a red is re-run solo before being
believed, and fixed at source, never in the test. Full history:
`README-PHASE1.md` + `docs/process/reports/`.

## Open risks (named, with fix paths)

- **R-19**: qemu payload defaults `OX_SKIP_VERITY=1` (verity skipped on
  the virtual target). The slot path ignores it (always enforces).
- **R-21**: s6-rc live-state doesn't come up under TCG; ox-init-stage2
  falls back to plain s6-svscan (longruns only — oneshots never run).
- **R-23**: guest dm-crypt skcipher lookup ENOENT even for registered,
  selftest-passed xts(aes) — see
  `docs/process/reports/2026-09-01-luks-data-volume.md` (has a
  next-session checklist). Data volume continues without encryption,
  loudly. **This is the top M2 blocker.**
- GC: after any big store cleanup run `tools/gc-keep-current.sh`
  (roots outputs AND drv closures AND kernel sources). **Chunk-78
  lesson: a plain `ln -sfn` into a repo dir is NOT a GC root** — nix
  only honors /nix/var/nix/profiles and `nix-store --add-root`
  registrations. The fake roots let the Oct-10 purge delete the whole
  toolchain (gcc rebuilt from source for hours). Verify with
  `nix-store --print-roots | grep oxbuild`.

## Next steps (M2), in order

1. R-23 live-debug (the checklist in the Sept report) → encrypted data
   volume in the guest.
2. Lift R-19: flip the payload to verity-enforced, re-run all gates.
3. Slot security ride-along: per-slot AVB descriptor + RPMB monotronic
   counters (chunk 76 report lists the shape).
4. Real hardware: `tools/make-flash-bundle.sh` → flash a PinePhone Pro,
   serial console, bring-up log. First device boot is the milestone.
5. CI (`.github/workflows/ci.yml`) — if it isn't green yet on GitHub,
   fixing it beats any new feature: free verification forever.

## Cheap-session protocol

Read this file → `tail -n 12 queue/board.txt` → pick ONE item from
"Next steps" → work it → gate it → append the README row + report →
stop. One green gate per session is a good day.
