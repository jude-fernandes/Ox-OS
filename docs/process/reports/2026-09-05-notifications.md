# notifd + permstored — notifications and the permission store

Date: 2026-09-05
Status: **DONE — NOTIFICATION GATE ALL GREEN** (two-boot gate: flow +
grant persistence across reboot; verdict at bottom)

## Scope

Phase 3 chunk: "notifd + intentd + permstore with honest permissions &
fake-data providers". This chunk lands two of the three:

### permstored — the permission store

- Persistent per-app grants in `/data/ox/permstore.json`, atomic
  writes (temp + fsync + rename), survives reboot.
- Three charter modes, strictly validated: **grant** (real data),
  **deny** (no access), **fake** (fake-data provider — the app gets
  plausible synthetic data and must mark it; the provider lands with
  the first data API, contacts for the dialer).
- **Default deny, fail closed**: an app with no stored grant is
  denied; if permstored itself is unreachable, callers (notifd) also
  deny.
- **Persist-or-refuse**: a mutation that cannot be saved is rolled
  back and refused — the store never shows a grant it failed to
  persist. (This exact bug was caught by the gate: the first run's
  `set` failed on a read-only /data but the in-memory grant leaked —
  the store now creates its directory at startup and rolls back on
  save failure.)
- IPC: `get` / `set` / `list`; every mutation kmsg-journaled
  ("perm journal app/perm -> mode").

### notifd — notifications

- Apps post over IPC; every post is permission-checked against
  permstored (`post-notification`); denied posts are refused and
  journaled ("notif journal stranger.app -> post DENIED").
- Accepted posts: in-RAM list (ephemeral by design — notifications
  die with the boot), list/dismiss/clear ops, and a banner window on
  the compositor drawn via ox-ui (best-effort; no compositor = IPC
  still works).

intentd is sequenced with the app-model chunk (`.oxp` + oxpkg) —
intents need real senders and receivers to be meaningful.

## Gate

`tools/notification-gate.sh` — **two boots**:

- **boot 1**: permstored + notifd up (`permstored-loaded`,
  `notifd-ready`); the selftest grants `post-notification` to
  `test.app` over IPC, posts (accepted, id returned), lists (drill
  title present), posts as `stranger.app` (refused — fail closed),
  stores a `fake` mode (accepted).
- **boot 2** (same payload clone: /data persists): `permstored-loaded
  apps=1 grants=1` — **the grant survived the reboot** — and the flow
  is green again.

Runner note: R-23 interim — the virtual target cannot unlock a LUKS2
data volume, so this gate runs the plain-ext4 data.img branch (key +
image removed from the clone; run-qemu's signature policy then formats
ext4). LUKS2 stays for hardware (risk register R-23 updated).

## Debug journey

1. `set` failed with "persist failed: ENOENT" — `/data/ox/` did not
   exist. permstored now creates its directory at startup (and exits
   fatally if it cannot — fail closed).
2. The gate then exposed the deeper issue: the in-memory grant had
   leaked despite the failed persist. Fixed with roll-back-on-save-
   failure.
3. After the persist fix, `/data` was still read-only — the data
   image was LUKS2-formatted (designed path) and R-23 blocks in-guest
   unlock. Fixed by the ext4 interim above; ox-init's ext4 fallback
   mount then provided rw /data.
4. Selftest socket wait raised 30 s → 120 s (cold-VM boot ordering).

## Honest limits

- Fake mode is stored and returned but no data API consumes it yet
  (arrives with contacts/dialer).
- Notifications are RAM-only (ephemeral by design).
- Banner is a single latest-notification card; grouping/ranking per
  the design language §5 lands with real apps posting real events.

## Verdict

**NOTIFICATION GATE ALL GREEN** (2026-09-05): boot 1 flow green
(grant → post accepted → listed → stranger refused → fake stored);
boot 2 `permstored-loaded apps=1 grants=1` — grant survived reboot —
flow green again.
