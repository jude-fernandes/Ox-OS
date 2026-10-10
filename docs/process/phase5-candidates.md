# Phase 5 candidate streams (planning note, 2026-09-16)

Scattered "Phase-5" flags across the board and reports, collected and
ordered. The closing sweep of Phase 4 decides when this starts; the
order below is the recommendation and the first three chunks are
already scoped.

## Chunk 54 — Guest-time budgets for gates (recommended first)

Every gate budget today is HOST wall-clock ("wait 120 s of real
time"), which is exactly what broke the wifi gate for two weeks: the
guest's second is not the host's second under TCG load. Move gate
waits to GUEST-SERIAL time: the kernel prints timestamps on every
console line (`printk.time=1` is already on), so a gate can wait
"2000 guest-milliseconds of serial-timestamp progress" instead of
host seconds — a stall (drop_caches, TCG crawl) then consumes GUEST
budget only as far as the guest actually progressed, and the
"unlimited window vs machine time" mismatch disappears. Design notes:
needs a host-side parser for `[ 123.456789]` prefixes (trivial), a
`wait_guest_ms` helper in the shared gate library, and migration of
the 16 gates' waits one gate per gate-run. The 200 ms-auth-window
class of bug (2026-09-16-wifi-timing-root-cause.md) is also visible
IN GUEST time — the same instrumentation now in hwsim makes the
remaining guest-time outliers measurable.

## Chunk 55 — Transport hygiene (secrets in IPC copies)

From the zeroization chunk: lockd now zeroizes its own buffers, but
every IPC request/response is JSON — parsed copies of PIN material
and PSKs live in transient heap until malloc reuses them. Scope:
serialize-lockd/sMS/oxwifid secret fields into fixed zerocopy
buffers, or expose a "secret" type that zeroizes on Drop through the
IPC layer; gate = extended pin-gate + wifi-gate legs with a
heap-scan canary (dump daemon RSS after N verifies, grep for the
secret). Honest boundary: this hardens the QEMU lab; DMA/secure
world is hardware-phase.

## Chunk 56 — Throttle + duress state persistence

The lockout throttle and the duress store are RAM-only (tracked item
from the throttle chunk): a reboot clears an attacker's backoff.
Scope: persist throttle state (monotonic-ish, tamper-tolerant —
signed with the existing per-install key) and the duress enrollment
under /data/ox alongside the PIN store; wipe on panic-wipe already
covers the store. Gate: pin-gate extended with reboot-persistence
legs (two-boot shape like the wifi credential gate).

## Later streams (order TBD by the board)

- **Package signature enforcement end-to-end** (pulled forward in
  phase-3 exit; the packaging flow signs today, verification is
  manifest-deep) — extend to a root-of-trust chain: install-time
  signature check against a shipped public key, revocation, and the
  key hierarchy per-store.
- **Panic-wipe crypto-erase** — destroy the LUKS volume key, not
  just files (needs the hardware/LUKS phase workstream).
- **oxctl daemon-side bounds** — the caller is bounded now
  (busybox timeout in selftests); the daemon-side unbounded wait is
  still open. Small chunk, pairs naturally with any other stream.

## Process note

The overnight watcher/queue system (Windows scheduled task + in-WSL
job runner, hidden VBS launcher) is now the standard machine
schedule: gates and sweeps run in limited-credit hours; agent windows
do triage, fixes, and docs. VM bounce daily 15:55 local, watcher
restarts 16:00/02:00. Queue protocol: one line per job in
/root/oxbuild/queue/queue.txt; board + NEEDS-AGENT are the readback.
