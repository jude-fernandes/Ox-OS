# Chunk 63 — oxcom survives suspend/resume (+ USB authorize load fix)

Date: 2026-10-01 (laptop-local Irish time)
Status: SHIPPED — workspace-test ALL GREEN, OXCOM-PM GATE ALL GREEN
(zero compositor deaths through a real suspend/resume), USB GATE ALL
GREEN on this tree (payload 854pxdd2lqaf630finka7x5ydhb34r5j).
CHUNK-63B ADDENDUM (same day): wifi autojoin hardening — see below.

## 1. oxcom PM resilience (the tracked product bug)

Chunk 62's boot-death hunt established that the compositor can die
silently around graphics setup, and the power drill was the prime
suspect. Chunk 63 delivers the honest instrumentation first, then the
assertion:

- **Exit-code journal** (oxcom's s6 run file): the wrapper now writes
  `oxcom: exited rc=<N>` to the kernel ring on every death — a silent
  kill self-reports its signal class (139=SIGSEGV, 134=SIGABRT,
  137=SIGKILL, 0/1=clean). No more invisible deaths, ever.
- **Boot retry**: the display probe retries up to 5× / 10s before the
  compositor serves displayless — a transient first-attempt failure no
  longer depends on supervisor restart timing.
- **The gate**: new `pm-oxcom-selftest` + `oxcom-pm-gate` — boots WITH
  the power drill (no off-flag; the drill suspends at boot+6s, RTC
  resume ~8s), waits for `pm-resumed`, then proves oxcom still serves:
  status answers and a post-resume screendump lands (screen.read
  granted per chunk 62). Death count is reported in the gate output;
  the assertion is SERVICE, not zero deaths.
- **Result on first run: zero deaths** through a real suspend/resume —
  the "compositor dies on the drill" theory is now measured, not
  assumed: with the rc journal in place, oxcom survived this boot
  clean. The 2026-09-29 boot deaths remain attributed to the pre-63
  binaries; if the double-death returns, it now self-reports its rc.

## 2. USB authorize→blockdev under sweep load (twice-failed, root-caused)

usb-gate failed the same leg in two consecutive sweeps (green solo each
time). Serial forensics: `DBG-USB-AUTH-DEV` was EMPTY — the selftest
re-derived the stick's device id from the KERNEL RING (`dmesg | grep
usb-added`) at authorize time, but under sweep load the ring wraps and
the plug-time line is gone by then; the empty id made the authorize
call a no-op. Fix: derive the id from the granted-list response the
selftest captured seconds earlier (`"dev":"2-1"` — usbd's own truth).
Solo run green immediately; the overnight sweep re-tests under load.

## Also in this tree

- `pm-oxcom-selftest` registered in the default bundle.
- The oxcom-pm gate follows house discipline (guest-clock budgets,
  offline build, fresh payload clone).

## Residuals

- The double-death's precise root cause is still unobserved (no rc
  captured yet — deaths stopped reproducing once instrumented). The
  journal guarantees the next occurrence self-reports.
- usb kernel-side plug defaults (chunk-57 follow-up) unchanged.

## CHUNK 63B ADDENDUM — wifi autojoin hardening (same day)

The chunk-63-tree overnight sweep: 13/16 — **usb PASSED under load**
(the ring-wrap fix held, `DBG-USB-AUTH-DEV 2-1` in the serial), but
wifi failed again, then three more times across solos — each a
DIFFERENT failure mode of the boot-time autojoin path:

1. Association measured 93 guest-seconds; EAPOL completed just AFTER
   the old 90s daemon deadline. Fixed: 300s.
2. Ctrl socket ENOENT at attach (t=176): the socket wait ran BEFORE the
   creds wait and exhausted first. Fixed: wait moved to immediately
   before attach.
3. `SET_NETWORK 0 ssid ... -> 1` refused mid-wpa-init (t=246). Fixed:
   the whole provision+wait cycle retries 3× with fresh network blocks
   (transient boot-order states recover on attempt 2+).

Also shipped after a stray-QEMU VNC-port collision poisoned a boot
("hwsim never probed" = QEMU never started): **38 gate runners gained
their own pre-boot pkill** (most had relied on the sweep's between-gate
cleanup; a failed gate leaves its QEMU holding VNC :1 and the next
runner to boot dies instantly).

Watch item, NOT fixed: wifi (and grid-event/uninstall) remain
solo-green but sweep-red rotators. Six solo runs each failed at a
different leg with boot-time milestones drifting (autojoin-start at
guest-28s → 176s → 246s across boots) — the guest clock's own pacing
shifts under load, which stresses fixed choreography in ways
guest-clock budgets only partially absorb. The overnight sweep (wifi
requeued last, after all regression gates) gathers the failure-rate
data; if the rotation persists, the wifi gate's older tap legs get the
count-verified treatment the grid gate received.

Next-chunk lead (2026-10-01 evening): **selftest internal-timeout
audit**. The switcher gate's 06:11 failure was `pkg-flow-ok` never
settling on a boot whose oxcom stage journals show a HEALTHY compositor
(attempt=1 ok=true, serving) — the in-guest selftests carry their own
hard-coded internal deadlines (pkg install cycles, notifd-flow waits,
dmesg polls) that a slow boot blows before the gate budget even
matters. The audit: enumerate every selftest's internal deadlines,
resize or make them event-relative, and re-baseline. oxwifid's
autojoin (this chunk) was the first member of this family fixed.
