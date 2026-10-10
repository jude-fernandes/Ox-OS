# Chunk 53: Wi-Fi association race — root cause found, timing fix shipped

**Date:** 2026-09-16 (evening window)
**Status:** root-cause fix VERIFIED where it aimed: the association
itself now lands deterministically under full concurrent boot-selftest
drill load (run 1 phase 1 COMPLETED at guest t=191 s where the
pre-fix runs timed out for minutes). Overnight chain result: wifi run
1 RED in PHASE 2 (the post-reboot AUTOJOIN leg never observed
`wifi-autojoined` — first boot after a 90-minute kernel compile, VM
at its slowest; phase-2 wait budget suspected, not proven — run 1's
serial logs were overwritten by run 2), wifi run 2 ALL GREEN
(association + persistence + autojoin, both boots). The 16-gate
closing sweep is running overnight on the same payload; if its wifi
leg hits the same phase-2 budget wall, the follow-up is: widen the
phase-2 host-side budget + one re-boot retry on the autojoin leg
(user semantics: a join that didn't land gets retried).

## The failure signature this explains

The wifi gate has been the one gate blocking the ALL-16 declaration:
green solo (×2 boots ×2 runs) but intermittently red inside full
sweeps (sweep9 13/16, sweep10 14/16, sweep11 13/16 — the failing gate
moved around, wifi being the most frequent). Every red looked the
same: `wlan0: authentication with 02:00:00:01:00 timed out` for
minutes, join op returning "association still pending", gate budget
expired.

## The diagnostic path (what was built and what it disproved)

1. **hwsim kernel instrumentation** (`ox-hwsim-debug.patch`): module
   param `ox_debug_unicast`; logs radio idx + reason for EVERY skipped
   unicast frame at the two drop points in
   `mac80211_hwsim_tx_frame_no_nl` (started/idle/PS skip, channel-miss
   skip), plus a tx-entry line for every unicast frame entering the
   delivery loop.
2. First build failed: the patch's `\n` escapes had become literal
   newlines in sync (see findings), and `data2->name` doesn't exist in
   `struct mac80211_hwsim_data` — `data2->idx` is the identifier.
3. Diagnostic run FAILED with **zero** `hwsim-dbg:` lines. Chasing
   that zero: verified the built `.ko.xz` has the strings, then the
   `ox-wifi-modules` drv output (initial false negative from piping a
   plain `.ko` through `xz -dc`; plain `strings` settled it), then the
   rootfs squashfs source tree — **the guest genuinely ran instrumented
   code with the param set Y**.
4. Therefore the frames were not dropped at hwsim's skip branches.
   The log showed the real shape: client→AP works (hostapd logs
   `authentication reply ... resp=0` — it RECEIVED auth and REPLIED),
   AP→client is lost, and the client retries on a **30–40 s cadence**
   (normal SME auth retry is ~200 ms). Nothing was late by a little;
   everything was late by orders of magnitude.

## Root cause

**mac80211's fixed 200 ms / 100 ms auth/assoc response windows vs
multi-second TCG stalls from concurrent boot selftests.**

- `IEEE80211_AUTH_TIMEOUT` = HZ/5 = 200 ms; assoc likewise. These are
  real-hardware assumptions.
- Ox boots run ALL boot selftests concurrently (s6 longruns). The
  resourced selftest's memory-pressure drill fires `drop_caches`
  every ~20 s and fills a tmpfs — each `drop_caches` stalls the whole
  TCG guest for seconds.
- The failed run's timeline shows the resourced drill active THROUGH
  the auth window. The AP's reply is constructed and sent
  (hostapd's log proves it); by the time it crosses the emulated air,
  the client's 200 ms window has closed. mac80211 kills the auth
  transaction, wpa_supplicant waits out its own backoff (~30 s), and
  the next attempt runs the same lottery.
- Whether a boot passes is therefore decided by whether the drills
  overlap the join window — exactly the observed "green solo, red in
  sweeps" coin flip. **The association race was never a radio bug.**

## The fix (three layers)

1. **`ox-mac80211-lab-timing.patch`** — the six auth/assoc response
   timeout macros in `net/mac80211/mlme.c` become module params
   (`ox_auth_timeout`, `_long`, `_short`, `ox_assoc_*`), **defaults
   byte-identical to upstream**; real-hardware semantics untouched.
2. **cmdline** (`tools/build-payload.sh`): `mac80211.ox_auth_timeout=1000`
   etc. — jiffies, chosen to be ≥3 s at any CONFIG_HZ (100/250/300).
   Applied at mac80211 load via standard cmdline module-param
   mechanism.
3. **wifi selftest**: runtime sysfs belt (same values) + `J`'s oxctl
   call wrapped in `busybox timeout 90` (the failed run also showed
   the selftest wedging past try=2 with no diagnostic — an unbounded
   `oxctl` under stall; now bounded).

Verification: overnight watcher chain runs the wifi gate twice and
then the full 16-gate sweep (`phase4-sweep.sh`) on this exact payload.
The honest verdict lands in the watcher board; this report gets its
closing line then.

## Findings (each cost real time; recorded to not cost it twice)

- **Heredoc escape mangling**: `\\n` in a `<< 'EOF'` heredoc piped
  into WSL landed as a real newline (collapsed one level). Any script
  that must EMIT a backslash builds it via `chr(92)` — no literal
  backslash sequences survive the pipeline reliably. Byte-verify
  (`od -c`) anything the compiler will parse.
- **Stale-store-output trap**: `ls -d /nix/store/*-ox-wifi-modules`
  shows only OLD outputs when the new drv's output hash is new (the
  glob can't know it). Ask the DRV for its output path
  (`nix derivation show`), never glob the store. Related: `nix
  derivation show` recurses into INPUT drvs — pin the exact key.
- **`pkill -f` self-match**: `pkill -f '[n]ight1.sh'` killed my own
  shell (the command string itself contained the pattern; the [n]
  trick only guards grep, not pkill's own cmdline). Requeue writes
  after any pkill, never inside the same command.
- **WSL session teardown kills setsid'd children** (systemd not
  actually running despite wsl.conf). The durable pattern that
  survived every test: Windows Task Scheduler task → `wscript //B`
  hidden VBS launcher → `wsl.exe --exec sh watcher.sh`. Duplicate
  guard via mkdir-lock + pidfile. ONLOGON triggers need admin; DAILY
  triggers don't.
- **Clock discipline**: schedule and report in LAPTOP-LOCAL time
  (Irish, UTC+1). The WSL clock drifts and is UTC — reading it for
  window math produced wrong statements twice in one session.

## Honest scope

- The fix widens lab timing windows; it does not make TCG fast. A
  sufficiently long stall (double-digit seconds) can still drop an
  exchange — the gate budgets and the 4-try re-join loop remain the
  honest backstop.
- `mac80211.ox_*` params are lab tuning, documented in the cmdline
  with rationale. If Ox ever ships on real hardware, defaults apply
  unchanged.
- The oxctl wedge (daemon-side unbounded wait under stall) is bounded
  at the caller now; the daemon-side bound is still open work.
