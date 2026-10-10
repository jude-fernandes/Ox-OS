# resourced — zram swap, PSI pressure tiers, protected OOM

Date: 2026-09-05
Status: **DONE — RESOURCED GATE ALL GREEN** (zram tier + PSI-driven
tier escalation under a real memory-pressure drill; verdict at bottom)

## Scope

Phase 2 "resourced (zram/PSI/OOM tiers)": `rust/crates/oxresourced`.

- **zram swap tier**: on boot, sizes `/sys/block/zram0` to 256 MiB,
  mkswap + swapon (busybox applets; zram + LZO are built into the
  kernel already — no rebuild was needed).
- **Pressure monitor**: polls PSI memory `some total` (µs) every 1 s;
  stall % = delta / poll interval — the instant pressure measure, not
  the sluggish 10-min averages. Also watches MemAvailable %.
- **Escalation tiers** (higher signal wins, 10 s per-tier cooldown):
  - tier1 warn → drop page cache
  - tier2 pressure → memory compaction
  - tier3 critical → SIGKILL the largest-RSS process not on the
    protected list (pid 1, self, and every Ox system daemon are
    protected; tier3 is armed + unit-tested, exercised in soak later)
- **Config over IPC**: thresholds settable at runtime via
  `oxctl resourced config '{...}'`; `status` reports availability,
  event counters, kill log.

## Gate

`tools/resourced-gate.sh`: requires `resourced-zram-ok`,
`resourced-ready`, then a `resourced-selftest` service that tightens
thresholds over IPC and fills tmpfs in 10 MB chunks — polling the
daemon's IPC status after every chunk — until tier1 and tier2 have
both fired (`resourced-tier-ok`). The selftest holds a `res-drill`
wake lock so the idle doze cannot freeze the drill, and cleans up.
Thresholds for the drill: warn 80 % / critical 75 % availability —
crossed early in the fill (avail starts ~87 %), making the drill
bounded (~175 MB of writes max) and speed-invariant. The gate waits
up to 1000 s for the drill (QEMU timeout 1100 s), because TCG speed
varies several-fold run to run.

## Debug journey

1. rustc: Arc move into two closures (E0382), AtomicU64 is not Copy
   (bad derive), missing `Read` trait import — three small compile
   fixes.
2. `/mnt` is on the read-only root; the drill's mkdir failed with
   "Read-only file system". Fix: the drill mounts its own tmpfs under
   `/tmp` (ox-init tmpfs-mounts /tmp).
3. The idle doze suspended the box mid-drill (17 suspend cycles in one
   boot). Fix: `res-drill` wake lock around the drill.
4. The gate raced the kmsg log writer: `resourced-ready` flushed a
   moment after `resourced-zram-ok`, and an immediate grep failed.
   Fix: wait loops for every milestone, never a one-shot grep.
5. Wall-clock dependence: a fixed-size fill plus fixed gate windows
   cannot survive TCG speed varying ~10× between boots. Final design:
   chunked fill with early exit (converges at any speed), thresholds
   crossed early in the fill (warn 80 % / critical 75 % availability),
   gate window (1000 s) sized above the drill's worst case
   (21 chunks × ~40 s).

## Honest limits

- tier3 kill path is implemented and unit-tested (victim selection,
  protection list) but not fired in the gate — it is exercised by the
  later soak/hardware work.
- QEMU has no thermal zones; thermald is a separate remaining
  Phase-2 item.
- No memory-bandwidth or performance claims (R-20 posture).

## Verdict

**RESOURCED GATE ALL GREEN** (2026-09-05): `resourced-zram-ok`
(256 MiB) → `resourced-ready` → tier1 `action=drop-caches` at
avail 80.0 % (the configured warn line) and tier2 `action=compact`
under the chunked tmpfs fill (`DBG-PRESS t1=21 t2=1`). An earlier
boot independently showed tier events firing before the gate windows
were widened — the escalation logic has been green in every run where
the fill was allowed to complete.
