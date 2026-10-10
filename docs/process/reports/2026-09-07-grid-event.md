# Grid refresh is event-driven — chunk 24, 2026-09-07

## Claim

The home grid no longer discovers package changes by polling. intentd pushes a
`pkgs-changed` event to a new shell event socket the moment an install or
remove commits, and the shell redraws the grid on its next bounded wake —
**~0.2–0.4 s end to end**, asserted from kernel timestamps at under 2 s (the
old poll could take up to 5 s and did no redraw at all while the package set
was unchanged).

## How it works

- **intentd** (`ox-intentd/src/main.rs`): after a successful `install` or
  `remove`, a worker thread connects to `/run/ox/sockets/shell-events.sock`
  and sends `pkgs-changed {app}` (best-effort, journaled
  `intent-pkgs-changed`; an absent shell just falls back to polling). The
  broadcast never delays the installer's reply — it runs off-thread.
- **ox-shell** (`ox-shell/src/main.rs`): serves the event socket with
  ox-ipc; the handler sets a `GRID_DIRTY` atomic. The main loop's
  `click-recv` wait is now bounded at **250 ms while unlocked** (5 s while
  locked — only the pad needs pacing there). A clean wake costs one atomic
  check; a dirty wake fetches the installed list from intentd and redraws
  only on a real change (`shell-grid-event-refresh` journaled). The old 5 s
  poll survives as a self-heal fallback for missed events, journaled
  distinctly (`poll fallback`).
- **Deterministic tile order**: intentd's `installed()` list is now sorted.
  It used to be `read_dir` order, so tiles could reshuffle boot to boot —
  and did, mid-gate (see findings). Unit-tested (sorted, `.oxp`-stripped,
  junk ignored).
- **grid selftest service** (`system/s6-rc-source/grid-selftest/`): waits
  for the UI unlock (dmesg), installs the staged `grid.oxp` (name
  **Gridtest**, empty permission set, dev-signed), holds 60 s, then removes
  it — retrying while the app is running, since intentd refuses to remove a
  running app.

## Gate evidence (`tools/grid-event-gate.sh` ALL GREEN)

From kernel timestamps in the serial log:

- `intent-install app=Gridtest` → `shell-grid-event-refresh`: **0.23 s**
  (0.17–0.30 s across runs) — budget 2.0 s.
- The refreshed tile is **live**: the gate taps Gridtest's spot and the app
  launches through intentd (`shell-launch` + `intent-start`).
- `intent-remove app=Gridtest` → second `shell-grid-event-refresh`:
  **0.36 s** (0.25–0.40 s across runs) — budget 2.0 s.
- After removal the same tap launches nothing named Gridtest (the fresh
  grid legitimately shows Hello on that spot — positive control that the
  grid is live).
- The shell event path itself is journaled end to end:
  `intent-pkgs-changed app=Gridtest` → `pkgs-changed event received` →
  `shell-grid-event-refresh`.

Workspace unit-test gate (wired into the payload) runs the new tests:
`grid_wait_ms` bounds (locked 5000 / unlocked 250), fallback cadence
(250 ms × 20 = the old 5 s), `installed()` sorting, and the PPM encoder
(BGRX framebuffer → P6 RGB).

## Instructive findings (all caught by the gate, all fixed)

1. **Tile order was filesystem luck.** Run 1 tapped Gridtest's expected
   spot and launched *Hello*: the boot selftest's Hello occupied dyn tile 0
   because `read_dir` happened to list it first, and Gridtest (installed
   later) was tile 1. Fixed at the source — intentd now sorts the install
   list — rather than by guessing coordinates in the gate.
2. **The remove hit `app-is-running`.** The launch leg proves the tile
   live, which means Gridtest (ox-hello, ~20 s lifetime) was still running
   when the selftest's single remove attempt fired; intentd correctly
   refused. The selftest now retries the remove (5 s cadence, 24 attempts).
3. **QEMU screendumps are dead on this target — replaced with compositor
   scene dumps.** Every report PNG since 2026-09-05 was a black frame
   ("Display output is not active."). Root cause, reproduced by probing a
   boot at t=10/15/35 s: the guest's FIRST suspend/resume (the powerd
   selftest drill, ~15-24 s after boot) permanently kills QEMU's host
   display surface, while every guest-side ioctl stays healthy (GETCRTC
   keeps reporting our fb; a full SETCRTC every 5 s does not recover it).
   Gates screendump minutes after boot — always post-mortem. Fix: oxcom
   gained a `screendump {path}` IPC op that rasters the CURRENT scene
   snapshot to a PPM from inside the guest (`oxctl oxcom screendump …`),
   QEMU-independent; grid-selftest captures both moments and the gate
   pulls them out of the data image with debugfs and asserts real pixels.
   This restores working screenshots for every future gate. (The nine
   2026-09-05/06 report PNGs remain black frames; their textual kmsg
   evidence is unaffected. Re-shooting them is tracked tooling work.)
5. **Guest data needs an explicit flush at capture time.** The removal
   dump first landed as a 0-byte inode: the gate killed QEMU ~22 s after
   the write, inside ext4's 30 s dirty-expiration window, so the metadata
   committed but the data never did. The selftest now runs `sync` after
   each dump, and the gate extracts via debugfs using the IMAGE path
   (`/ox/artifacts/…` — the data volume's root mounts at `/data`).
4. **Kernel-timestamp assertions.** kmsg lines reach the serial log twice
   (console echo without timestamps, printk mirror with
   `[  <mono>]`); the gate's latency assertions only trust the
   timestamped mirror.

## Artifacts

- `2026-09-07-grid-event.png` — the event-refreshed grid with the live
  Gridtest tile (compositor scene dump, captured in-guest during the
  selftest hold).
- `2026-09-07-grid-event-removed.png` — the same grid after removal:
  Gridtest's tile gone (event-refreshed).
- Serial log: `/tmp/ox-gridgate/serial-grid.log` (guest-side, transient).

## State of the shell loop after this chunk

Locked: 5 s bounded waits (pad pacing). Unlocked: 250 ms bounded waits;
`GRID_DIRTY` → refresh; every 20th clean wake (≈5 s) → fallback check.
No intentd round-trips happen while the package set is unchanged.
