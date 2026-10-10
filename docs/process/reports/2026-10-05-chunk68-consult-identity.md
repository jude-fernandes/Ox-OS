# Chunk 68 — kernel-verified identity for every permission consult

Date: 2026-10-05
Status: CLOSED — all nine verification gates green

## The hole

Chunk 62 gave oxcom's screendump a kernel-verified caller identity
(SO_PEERCRED pid → /proc comm) and recorded the residual: "wifid-style
consults trust client-claimed names". The audit found it everywhere —
NINE daemons consulted permstored with the `app` string from the request
payload: camerad, contactsd, locationd, messagesd, nfcd, usbd, oxmodemd
(×4 ops), oxwifid (×2), notifd. Any app could claim a granted app's name
and inherit its grant. oxmodemd's sms-send even had a documented
loophole: "un-attributed callers are the system surface" — omitting the
claim meant grant.

## The fix

1. **`peer_comm()` promoted into ox-ipc** (next to `conn_peer_pid`):
   the kernel-verified peer process name, available to every daemon.
   oxcom's local copy deleted; it now uses the shared one.
2. **All 11 consult sites across 9 daemons** switched to the peer comm;
   payload `app` claims are ignored for authorization (notifd keeps the
   claim as display metadata). Unknown identity fails closed.
   oxmodemd's omission-loophole is gone: every caller consults.
3. **The grant identity model made coherent**: the permission identity
   is the PROCESS (kernel comm) —
   - selftests drive daemons via oxctl → grants name `oxctl` (44 seeds
     realigned via `tools/chunk68-grant-alignment.py`)
   - installed apps consult as their manifest `bin` (the spawned
     process's actual comm): ox-sms, ox-dialer, ox-camera
   - intentd now binds package permissions under `bin`, journaling
     `perm-bound app=Hello identity=ox-hello`
   - gnssd's locationd consults use `gnssd`; the Settings wifi panel
     uses `ox-settings`
4. **In-guest spoof proof** (acl-selftest leg 6): ox-hello is GRANTED
   contacts.read, oxctl is NOT — oxctl claiming `{"app":"ox-hello"}` is
   refused (`acl-spoof-refused op=contacts-list`), because the consult
   uses the comm. ACL gate now has five sides: SYSTEM/NORMAL/INPUT/
   SANDBOX/IDENTITY.

## What the verification chain shook out (every red, named)

- **contacts gate FAIL**: a payload-build race shipped an s6 DB missing
  oxcom (`s6-supervise: unable to chdir`) — the shell loop-exited. Root
  fix: the sweep's s6 integrity guard is now INLINE in all 37 gate
  runners (`tools/chunk68-runner-guard.py`) — this class fails at build
  time, by name.
- **notify gate FAIL ×3**, each a real latent bug the identity change
  exposed (all fixed):
  1. the grants panel re-sorted (Hello → ox-hello): ox-settings now
     journals every rendered permission row (`perm-row row=N app=… y=…`)
     and the gate derives the tap — then fixed the derivation to
     SCREEN space (window-new offset + row center; the first attempt
     toggled the row one pitch up)
  2. the artifact-leg python helper was missing `time` in its imports
     (pre-existing, first reach)
  3. the relaunch leg tapped a FIXED tile coordinate that hit Camera
     when Hello sat in dynamic slot 3 — now derived from `home-grid
     dyn=` (the grid-dyn lesson, third application)
- **wifi gate FAIL ×2**: the scan-leg grant still named "Settings"
  while the caller is oxctl (fixed), then the panel tap at (835,642)
  sat in the shell footer's band (y≥640) and lost the z-order lottery —
  nudged 12px up, inside the button (the uninstall pixel-boundary
  lesson). In-guest selftest portion was ALL GREEN throughout.
- **compositor wedge ×2** (contacts boot 1, notify boot 2): the known
  virtio-gpu modeset-block class (no `stage serving`, no exit journal,
  process alive) — both boots' gates green on solo re-run. Environmental;
  the chunk-64 solo-re-run procedure applied.

Process note, honestly recorded: the wifi scan-grant fix was applied on
the WSL tree and then OVERWRITTEN by a Windows-tree sync (the two-tree
rule bit again) — the second failure was that overwrite, not the fix.
Canonical edits happen on Windows, sync once, verify in-WSL after.

## Verification

- workspace-test ALL GREEN (identity change compiles across 12 crates;
  all existing tests intact)
- Gate verdicts (final runs): BOOT-HEALTH ×3 PASS, ACL PASS (5 sides),
  CONTACTS PASS, FAKE-PROVIDERS PASS, CAMERA-APP PASS, SMS-APP PASS,
  MT-CALL PASS, WIFI PASS ×2, NOTIFY PASS

## Watch items

- intentd's start/stop take an app NAME as the operation target —
  operation-target naming is not a consult, but its authorization
  surface (who may start/stop what) is unexamined; candidate chunk.
- The compositor wedge (virtio-gpu modeset across load spikes) remains
  the dominant environmental; kernel-side fix queued as watch item.
