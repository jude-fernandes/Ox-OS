# Chunk 69 — intentd authorization: the app lifecycle is system-only, and packages cannot impersonate

Date: 2026-10-05
Status: CLOSED — all verification gates green

## The surface

intentd owns the app lifecycle (start/install/remove/stop) and answered
any caller: an installed app could stop another app mid-flow, remove a
package, or start apps unbounded. Adjacent to it, chunk 68's identity
model created a packaging route to spoofing: a validly SIGNED package
declaring `bin: "ox-settings"` spawns a process whose kernel comm IS
`ox-settings` — inheriting that identity's grants (chunk 68 made the
comm the permission identity).

## The fix

1. **Lifecycle ACL**: `start`/`install`/`remove`/`stop` require a
   system client — {ox-shell, ox-settings, oxctl, oxpkg}, the built-in
   binaries with legitimate lifecycle roles (shell drives launches and
   the switcher, ox-settings the Apps panel, oxctl/oxpkg the dev and
   selftest surface). Refusals journal
   `intent-acl-refused op=… caller=… app=…`. `list` stays open
   (read-only). Installed apps have no lifecycle powers.
2. **Reserved bins**: `install` refuses any manifest whose `bin` is a
   built-in system identity (28 names — every /usr/bin daemon and
   system client; the four legitimate package bins ox-hello/ox-camera/
   ox-dialer/ox-sms stay free). The refusal fires AFTER signature
   verification — a valid signature does not rescue an impersonating
   bin — and journals `install-refused-reserved`.
3. Unit tests: the reserved set covers the system identities and keeps
   the package bins free.

## In-guest proof

- `impersonation.oxp` staged in the rootfs: VALIDLY SIGNED, manifest
  `bin: ox-settings`. The pkg selftest installs it and requires
  refusal: `DBG-IMPERSONATION oxpkg: install refused: bin 'ox-settings'
  is a reserved system identity` → `install-refused-reserved
  bin=ox-settings`. The pkg gate waits for it.
- The system-caller paths regress-tested green: uninstall (ox-settings
  remove + oxctl/oxpkg in selftests), switcher (shell start/stop),
  pkg (oxpkg install/start).

## What the chain shook out

- The pkg selftest's deny-leg (post-by-oxctl expected refused) died
  under chunk 68's grant alignment: notifd-selftest grants oxctl
  post-notification at every boot, and the permstored space is
  boot-global — so every oxctl post is "granted". The leg now asserts
  the honest property: the freshly-started Hello APP's own post is
  refused (ox-hello bound deny → `hello-notify-denied`).
- pkg-gate's artifact helper had the same pre-existing missing-`time`
  import notify-gate had (second reach, one-line fix).

## Verification

- workspace-test ALL GREEN (intentd ACL + reserved-bin unit tests)
- BOOT-HEALTH, UNINSTALL, SWITCHER, PKG gates ALL PASS (pkg with the
  new impersonation leg)
- Watch items carried: the compositor modeset wedge (environmental);
  the AP wedge; hardware fleet.
