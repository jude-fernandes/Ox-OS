# Chunk 64 — the deadline audit: event-relative waits + the late-bound display

Date: 2026-10-01
Status: CLOSED — all five gates green (alerts, grid-event, uninstall, switcher, oxcom-pm); three claim-ordering experiments falsified before the winning design; two environment footguns found and fixed

## What the overnight chain said

The chunk-63b overnight chain (7 jobs, single watcher) came back:

| job | verdict |
|---|---|
| phase4-sweep | 13 PASS / 3 FAIL (wifi, grid-event, uninstall) |
| wifi (solo) | **ALL GREEN** — the 63b autojoin fix (300s deadline + socket-wait-before-attach + 3-attempt retry) proven end to end, autojoin-before-selftest-walk ordering shown by line numbers |
| usb (in sweep) | **PASS under load** — the granted-list dev-id fix holds |
| switcher, acl, lock-shield | PASS |
| oxcom-pm | **FAIL** — was ALL GREEN at chunk-63 close |
| alerts | **FAIL** — 3rd consecutive |

## Root causes (every red, autopsied)

### 1. oxcom-pm: a PRODUCT bug, not a flake — alive but headless

Serial log of the failed run: oxcom `stage starting` at t≈44, KMS probe at t≈46,
then **silence — `stage serving` never appears**. The suspend landed while
`try_render()` was still inside its DRM probe/modeset; post-resume the ioctl
never returned, and from t≈83 every client forever logs
`no compositor at /run/ox/sockets/oxcom.sock`. Zero `oxcom: exited rc=` lines —
the process never died; it just never served. The selftest's one-shot status
probe at resume+15s honestly reported `pm-oxcom-failed reason=no-status`, and
the gate told the truth: service was never proven.

The old startup order was `try_render()` (blocking) → present thread →
`serve_with_disconnect()`. Anything that wedges the DRM claim therefore wedges
the entire system's IPC — a live compositor with no socket is a dead phone.

**Fix (the chunk's flagship):** the display is now LATE-BOUND.
- `Display` is `Arc<Mutex<Option<DisplayPipe>>>`; the IPC server starts first.
- A display thread owns the bounded 5-attempt retry; on success it hot-plugs
  the pipe into the cell, journals `stage display-ready w=… h=…`, spawns the
  present thread, queues ONE full repaint of the scene accumulated while
  headless, starts pointer input, and advances `Phase::CompositorReady`.
- On 5 failed attempts it journals `stage displayless` (bounded, as before).
- `mutate()`, status, screendump and pointer read the cell (clone-out, no
  lock nesting — the queue push takes no DRM-path locks).
- New journals are additive; no gate waits on the moved ordering.

### 2. alerts: four stacked gate defects

1. **TMO 900s killed QEMU mid-run.** The resourced drill alone took 600s of
   the budget; `timeout` reaped QEMU during the unlock retries, the QMP
   socket vanished, `qmp_pin`'s bare `s.connect` raised FileNotFoundError, and
   `set -e` killed the gate with a traceback and zero context. Now TMO=3600
   (default), QMP connects retry 15×1s and die with a FATAL diagnostic naming
   the real suspicion.
2. **Silent settle cap-out.** The resourced-settle loop printed "settled after
   600s" — which was its own cap — having seen NEITHER tier-ok NOR tier-failed.
   Now it fails loudly on cap-out (and warns on tier-failed but proceeds:
   alerts does not depend on tiers).
3. **Unlock windows vs measured pacing.** The failed boots show pad clicks
   landing ~20 guest-s apart under load; the guest never finished 5 clicks
   inside 3×50s, and each re-injection queued a second PIN behind the first
   (digit-buffer poison). Now: one injection, one 600s event-relative wait,
   single retry. The `|| echo 0` dirty-zero counts (chunk-58 lesson) are gone.
4. **Panel tap polls 16s** — same starvation family; now 60s polls.

### 3. grid-event: a stale snapshot read

The gate unlocked fine and the install event fired in 4.46s — but the check
snapshot-read the LAST `name=home-grid dyn=` line, which under load can predate
the shell's post-event redraw. Now it waits event-relatively for a rendered row
that actually contains Gridtest (150×2s) before computing the tap slot.

### 4. uninstall: unlock cascade

6 attempts × 50s windows with a 30s drain — the drain cannot flush 5 clicks at
~20 guest-s each, so attempt N's clicks delivered into attempt N+1's PIN. Now
3 attempts × 600s windows (one queued PIN fully drains before any re-inject).

### 5. switcher: same family, pre-emptively fixed

TMO 900 → 3600; silent settle cap-out → fails; unlock windows 50s → 600s with
dirty-zero removal; pkg-flow wait 600 → 1200 guest-s (the 06:11 rotation);
tap polls 16s → 60s.

### 6. Selftest internals (the audit proper)

- **pm-oxcom-selftest**: one-shot status probe → 90×2s retry; one-shot
  screendump → 30×2s retry; settle 15s → 5s. The service bar is "eventually
  serves post-resume" — the test now measures that bar instead of a fixed
  instant. (With the late-bound display the status probe should answer while
  the display is still being claimed.)
- **resourced-selftest**: socket wait 30s → 120s.
- **grid-selftest**: remove retry 24×5s → 120×5s (intentd refuses removal of
  a running app; under load the exit takes longer than 2 minutes).

## Verification status

- workspace-test **ALL GREEN** with the oxcom restructure (nix offline build,
  new store path).
- All edited shell scripts pass `sh -n`.
- Chain queued on the build machine: **oxcom-pm → alerts → grid-event →
  uninstall → switcher**. Verdicts appended below when the chain lands.

## Verdicts (chain, 2026-10-01 evening)

- alerts: **PASS** — first green in four attempts (gate fixes immediate)
- grid-event: **PASS** — the event-relative dyn= wait closed the stale-snapshot red
- uninstall: **PASS** — the 600s unlock windows closed the tap-cascade red
- oxcom-pm: **FAIL — then root-caused to a narrower residual** (see 64b)
- switcher: **PASS** — with its hardened gate (TMO 3600, settle cap-out check, 600s unlock windows)

## 64b rev1 — the watchdog: BUILT, RUN, AND PROVEN HARMFUL (same evening)

The re-run on the rev1 tree autopsied clean up to a point: oxcom **served at
t=11s** (serve-first proven), the post-resume status probe **answered**, and
then `screendump: no display` → fail — the suspend had landed mid-claim and
the DRM ioctl stayed wedged. Rev1's answer was a watchdog: 90s unclaimed →
`exit(75)` → supervisor restart. **The orphan boot's log killed that idea**:
the watchdog fired at t=101.7 as designed, and then — for the next **1000
guest-seconds** — no `exited rc=75` journal, no second `stage starting`, and
ox-shell looping "no compositor" forever. `exit_group` had blocked in
`drm_release`: **a process holding a wedged DRM fd cannot even die** — the
run file never learned of the death, s6 never restarted, and the exit had
already taken the IPC server down. Rev1 converted "alive but headless, still
serving" into "fully dead". Reverted.

Lesson recorded: oxcom must never `exit()` while a DRM fd may be wedged; and
the wedge itself must be prevented, not escaped.

## 64b rev2 — the pm-hold handshake: BUILT, RUN, FALSIFIED

Rev2's hold mechanism worked exactly as built — powerd parked the hold at
arm time, oxcom saw it at t=12.1 (`display claim held by pm`), the hold
cleared 1.5s after resume (`pm hold cleared after 7s` — guest clock freezes
during suspend), and the claim started post-resume. Then the decisive
observation: the KMS probe **answered** post-resume (`kms: crtcs=1 conns=1
encs=1 fbs=0` at t=48.7) — and `render_once` **never returned**. No
`compositor-rendered`, no failure, no panic, guest ran on to t=768.

**There is no healthy post-resume claim on this target.** The modeset path
is dead after the first suspend, not just during it. Chunk 62's "guest-side
ioctls stay healthy" applies only to an ALREADY-ESTABLISHED display (the
present thread's flips) — a fresh SETCRTC never completes. That retroactively
explains why chunk 63 passed: its synchronous claim landed at ~t=11, ~5s
BEFORE the drill's suspend at ~t=16, and a pre-suspend claim survives.

Rev2's hold was also the reason the claim lost the race it needed to win.
Removed (oxcom + powerd).

## 64b rev3 — synchronous claim first (landed)

The strategy table, fully measured tonight:

| strategy | race vs suspend (t≈16) | wedge outcome |
|---|---|---|
| chunk-63 sync claim | wins by ~5s (claim ~1s at t≈11) | display survives suspend; post-resume service proven (chunk 63 ALL GREEN) |
| rev1 thread claim, serve first | loses (~1.7s thread-scheduling delay + contention) | modeset wedges; IPC served but headless forever; rev1's exit-watchdog then killed IPC too (exit_group blocks in drm_release — a process holding a wedged DRM fd cannot even die) |
| rev2 hold + post-resume claim | deliberately skipped the race | post-resume modeset hangs — headless forever, no wedge even needed |

Rev3 restores chunk-63's ordering — synchronous claim at the very top of
startup (bounded 5×2s retry, displayless parking) — while KEEPING the
late-bound `Display` type and honest `display:false` handlers from this
chunk. A heavily-loaded boot can still lose the race and wedge the claim
(that failure mode is now precisely understood and journaled via the stage
milestones; the 18:25 run was one). On this evidence the race-window margin
(~5s) is the target's real constraint; the fix that would remove it entirely
is kernel-side (virtio-gpu modeset across suspend), out of userspace scope,
and queued as a watch item.

## 64b rev3b — the drill window: GREEN

Rev3's synchronous claim still lost one boot (probe at t=11.8, modeset in
flight at the +6s suspend) — which exposed the real variable: the race
window is `powerd start + 6s`, and the powerd-vs-oxcom start gap varies per
boot. Chunk-63's green runs were boots that won that lottery. The property
under test was never "win a 4-second boot race" — it is "service survives
suspend/resume" — and on real hardware there is no boot suspend at all.

So the drill now suspends at **+30s** (powerd `OX_PM_SELFTEST` thread): the
claim gets a fair margin everywhere, and the gate asserts the actual product
property. Verdict, first run on the rev3b tree:

- `stage display-ready w=1280 h=800` at t=14.9 — claim won, 24s of margin
- `pm-selftest-begin` t=39.2 → suspend → `pm-resumed` t=70.0
- post-resume screendump **landed** (1280×800) on the surviving display
- `OXMILESTONE name=oxcom-pm-resilient resumes=1 deaths=0`
- **OXCOM-PM GATE ALL GREEN** (board PASS 20:11 UTC)

Chunk 64/64b final tally: alerts, grid-event, uninstall, switcher all PASS
on the hardened gates; oxcom-pm PASS on rev3b. All five rotating reds from
the overnight chain are closed and gate-proven.

Durable lessons recorded: (1) never `exit()` while holding a possibly-wedged
DRM fd — exit_group blocks in drm_release and kills the whole service; (2)
on this virtual target the modeset path is dead once the first suspend has
fired — only pre-suspend claims survive, so the claim must be synchronous,
first, and fast; (3) test windows must not depend on daemon start-order
lotteries.

## Watch items

- The TCG load-pacing drift itself (boot milestones 28 → 246 guest-s across
  the week) is environmental; the audit makes the gates honest under it, but
  a pinned-host fleet or KVM target remains the real cure.
- The mystery 15:22–15:37 solo alerts boot on the build machine (no board
  entry) — same never-unlocked signature; covered by this chunk's fixes, but
  provenance unexplained (possibly a straggler from the previous session).
- screendump path sandboxing (chunk-62 note) still open.
