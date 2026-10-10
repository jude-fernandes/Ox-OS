# Chunk 62 — screen.read: the screendump is permission-gated

Date: 2026-09-30 (laptop-local Irish time)
Status: SHIPPED — workspace-test ALL GREEN, ALERTS + SWITCHER + GRID
EVENT gates ALL GREEN on the chunk-62 tree

## What shipped

The compositor's `screendump` op (the guest's screenshot: the whole
screen's pixels, any window's content) is now permission-gated — the
last wide-open read surface found in the chunk-60/61 audit:

- The caller's identity is the SO_PEERCRED pid's /proc comm
  (kernel-verified; the first identity-gated permstored consult in the
  tree — oxwifid-style consults trust client-claimed app names).
- The consult asks permstored for `screen.read`; anything but an
  explicit `grant` refuses (unbound default = deny, matching the
  negative matrix; `fake` is meaningless for screen content and
  refused). Fail-closed on every error path. Refusals journal
  `acl-refused op=screendump app=<comm> mode=<mode>`.
- The three in-guest selftests that dump (grid, alerts, switcher) grant
  `oxctl` screen.read before dumping — the gate artifacts still
  materialize, proving the granted path end to end.
- `sendkey` was scoped OUT: it is a QEMU monitor command injected
  host-side, not a guest IPC surface — outside the guest threat model.
  Documented so nobody "gates" it in the wrong layer.
- Unit test: screendump fails closed (`acl:` refusal) with no
  permstored reachable.

## Durable diagnostics added (paid for by this chunk's debugging)

- **oxcom panic hook → kmsg**: the service run file does not redirect
  stdio to the console, so a panic in any thread died invisibly. Panics
  now land on the serial (`oxcom PANIC: ...`).
- **Startup stage journals** (`stage starting` / `stage
  display-probed` / `stage serving`): a silent death now localizes
  itself.

## The boot-death hunt (honest record)

Alerts/switcher gates failed with oxcom dying silently between the KMS
probe and socket bind — twice restarted, no panic text. The stage
journals + the absence of a panic line localized it to a SIGNAL death
in DRM setup, and the serial showed `pm-selftest-begin` right after:
these two gates boot WITHOUT `ox.pm_drill=off`, and powerd's
suspend/resume drill kills the compositor mid-DRM-setup. **Product bug
(oxcom must survive suspend/resume) — tracked for its own chunk**; the
gates now boot with the drill off like every other tap-driven gate.

Then the seeding leg failed: notifd-selftest wrote its flow-ok
milestone to the CONSOLE only, while alerts-selftest waits for it via
`dmesg` (kernel ring) — a waiter that can never succeed; it always
burned its full 120s timeout before seeding, past the gate's budget.
Fixed at the root: the milestone is now also written to /dev/kmsg, and
the alerts/switcher gates migrated to guest-clock waits (chunk-54
discipline; 7 waits in switcher, 1 in alerts).

And once again the duplicate-fleet lesson: mid-debug I launched a
second ad-hoc gate chain while the first was still on its long grid
leg — the two chains' pkills killed each other's boots (54-line serials,
"no shell-locked" out of nowhere). Killed both; gates re-ran clean ONE
at a time. The rule stands: pgrep before launching anything.

## Earlier today (chunk-61-tree overnight chain)

Sweep 15/16 (wifi, mt-call, grid-event, uninstall — all four previous
failures — now PASS; usb-gate tripped its authorize→blockdev leg under
load: green solo twice before, watch item), throttle-persist PASS,
acl-gate PASS, lock-shield PASS. The chunk-60/61 security work holds
under the full gate battery.

## Residuals

- oxcom suspend/resume resilience — tracked product bug (above).
- usb-gate load flakiness — watch item, needs its own guest-clock audit
  of the authorize→blockdev leg.
- screendump writes any path the caller names (root FS); path sandboxing
  is the same follow-up as the input-injection consult.
