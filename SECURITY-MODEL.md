# Ox OS — Security Model (virtual target, through phase 5)

Date: 2026-10-05 (phase-5 exit artifact)
Scope: the QEMU virt target through phase 5 (chunks 58–70). Every rule
below is enforced in code and asserted by a gate; the gate names are
cited. Hardware bring-up (PinePhone Pro / FP5) re-runs the same gates
against real radios and silicon.

## The identity primitive

**A process is its kernel-verified comm — nothing else.** Every
Unix-socket connection is stamped at accept with the peer's pid
(SO_PEERCRED, ox-ipc); `peer_comm()` resolves it to `/proc/<pid>/comm`.
Payload claims (`"app":"…"`), process arguments, and environment are
never identity. Demonstrated in-guest: a copy of oxctl under another
name is refused where oxctl is accepted (ACL gate, WRITE side), and a
granted app's name in a payload confers nothing (IDENTITY side).
Installed apps' comm is their manifest `bin`; a package declaring a
system bin is refused at install (pkg gate, reserved-bin leg).

## Trust boundaries

| boundary | rule | where | gate |
|---|---|---|---|
| Permission store reads | fail-closed consults by daemon intermediaries; unbound = deny; unreachable = deny | permstored + every consult daemon | negative-matrix, acl |
| Permission store writes | system writers only: ox-settings (the user's panel), oxctl (dev), ox-intentd (bind/unbind) | permstored | acl (WRITE side) |
| App lifecycle (start/stop/install/remove) | system clients only: ox-shell, ox-settings, oxctl, oxpkg | intentd | pkg, uninstall, switcher |
| Package identity | signed manifests; reserved system bins refused after signature verify | intentd | pkg |
| Screen pixels | `screen.read` grant, kernel-verified caller; dumps sandboxed to /data/ox/artifacts (O_NOFOLLOW) | oxcom | acl (SANDBOX side) |
| Input | input waits process-scoped (a foreign process cannot read the pad's taps); the lockscreen is a secure compositor tier apps cannot cover or tapjack | oxcom | acl (INPUT), lock-shield |
| Lock secret | hashed verifier, throttled lockouts that stop attackers not owners, duress PIN separates; the secret's non-UI owner is lockd | lockd | throttle-persist |
| Transport | every PIN/PSK copy on the wire is volatile-zeroed at auditable boundaries | ox-ipc | workspace tests |
| Power/resourced | wake locks owned and released on death; tiers bounded | powerd/resourced | oxcom-pm, thermal |
| Boot | every daemon exit self-reports (`NAME: exited rc=N`); boot completeness asserted by name | s6 run files, boot-health-selftest | boot-health |

## The invariants

1. **Default deny everywhere.** Unbound permission = deny; store
   unreachable = deny; unknown peer = deny. Grants are the user's,
   expressed only through the grants panel — and the panel is the only
   app that can write the store.
2. **Identity is not claimable.** The three routes to faking it are
   closed: payload claims (ignored), comm spoofing by packaging
   (reserved bins), and copied binaries (different comm, refused).
3. **Every refusal journals evidence with the caller named.** The
   refusal classes: acl-refused, intent-acl-refused, perm-acl-refused,
   install-refused-reserved, boot-daemon-down, `exited rc=`.
4. **Failures are honest.** Gates fail on absent patterns rather than
   fake passes; every red gets a solo re-run before it is believed; the
   exit code and the log must agree (the false-PASS bug was a chunk of
   its own).

## Known limits (honest)

- The virtual target's compositor can wedge its initial modeset if a
  suspend lands mid-claim (virtio-gpu kernel behavior); the drill is
  scheduled to avoid it and the failure is loud (stage journals, exit
  journals) — the real fix is kernel-side.
- `sendkey`-style host injection is out of scope (host-side, outside
  the guest threat model).
- Dev signing keys ship in the tree for the package gate; production
  keys replace them at hardware bring-up.
- LUKS is hardware-gated; the virtual target runs plain ext4 (R-23
  interim, documented in the runners).
