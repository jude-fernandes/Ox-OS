# Chunk 53 close-out prep (fill on ALL-16 verdict)

Scratch sheet for the Phase-4 closing window. Everything below is
written; only the {VERDICT} fields get filled from the board.

## Sweep verdict read (first command of the window)

wsl -u root bash -c "sh /root/oxbuild/tools/sweep-verdict.sh"

## Board row text (README-PHASE1.md, replace the chunk-52/53 row)

| **Phase 4 close: wifi timing root cause + gate hardening + machine
infra** | {VERDICT: DONE (ALL-16 sweep <date>, log path) or PARTIAL
(13/16 + failed-gate analysis)} — the two-week intermittent
"auth timed out" association race was root-caused to mac80211's fixed
200 ms auth/assoc response windows losing to multi-second TCG stalls
from concurrent boot selftests (resourced drill drop_caches): the AP's
reply arrives late, not dropped (hwsim tx-entry instrumentation +
hostapd reply logs prove the path). Fix: ox-mac80211-lab-timing.patch
(six response-window macros → module params, defaults byte-identical
to upstream; lab boots raise them ~5x via cmdline
mac80211.ox_auth_timeout=1000 et al.); wifi selftest sets the same at
runtime and bounds its oxctl calls. Association now deterministic
under drill load (phase-1 COMPLETED at guest t=191 s in the run that
pre-fix timed out for minutes). One residual: the phase-2 autojoin
budget can expire on a >8 h-degraded VM (run1 RED / run2 GREEN same
payload; retry semantics queued if it recurs). Machine infra gained:
in-WSL job watcher (Task Scheduler + hidden VBS, duplicate-guarded,
self-healing every 30 min), job queue + board + NEEDS-AGENT protocol,
daily 15:55 VM bounce, daily 15:45 nix GC — with REAL gcroots in
/nix/var/nix/gcroots/auto (the decorative -o symlink lesson cost a
full rebuild: see findings) | {VERDICT} | 2026-09-16-wifi-timing-root-cause.md, 2026-09-17-chunk53-closeout-prep.md |

## Findings to fold into the wifi-close report (already in the file)

- heredoc backslash-collapse; chr(92) discipline; od -c verification
- stale-store-output trap: query the drv, never glob the store
- pkill -f self-match footgun
- WSL session teardown vs setsid; Task Scheduler + VBS pattern
- clock discipline: laptop-local (Irish) time only
- decorative gcroots: -o symlinks are not roots; gcroots/auto is
- relative paths in queue jobs die on CWD (watcher now cd's)

## Phase 5 opening (chunk 54)

Guest-time budgets for gate waits — see phase5-candidates.md. First
task after Phase 4 closes; the wifi incident is its motivating
evidence.
