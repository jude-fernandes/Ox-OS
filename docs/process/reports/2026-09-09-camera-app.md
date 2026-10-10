# Camera app v1 — chunk 36, Phase 4, 2026-09-09

## Claim

The Camera app closes the camera vertical end to end: the app ships
as a SIGNED .oxp package (the packaging flow installs it at boot and
the manifest-permission rule binds camera.read=deny for it), appears
as a dynamic home-grid tile, launches through intentd, and draws a
LIVE viewfinder (real sensor frames from ox-camerad through the new
compositor pixels op) with the red CAM LIVE badge. The honest
permission lifecycle is on-device and observable: the first frames
are REFUSED by the bound deny (the app shows "camera denied — grant
Camera in Settings"); when the user grants, the viewfinder goes live;
the status CARD — a surface OUTSIDE the camera app — shows the CAM
chip the whole time and clears when the app closes; the shutter saves
a real sensor frame to /data/ox/DCIM; Close reaps the app and the
indicator clears.

## Stack layers (all gated)

1. **Compositor pixels op**: `{"t":"pixels",x,y,w,h,scale,data}`
   — base64 RGB24 rows, each source pixel drawn scale×scale
   (encoder in ox-ui, decoder + blit in oxcom, both unit-tested;
   corrupt base64 is rejected atomically). This is the first
   raw-bitmap primitive in the toolkit; everything else is still
   rects + text.
2. **ox-camerad frame/active ops**: `frame {app}` is
   permission-checked like a capture (deny/fake/grant), serves a
   160×120 nearest-neighbor downscale (base64, ~77 KB IPC budget),
   animates the fake mode (phase-shifted synthetic stripes — visibly
   live, visibly not the sensor), and journals every frame.
   `active` reports a frame within the last 5 s.
3. **ox-camera app**: viewfinder (1 s poll), shutter, honest states
   (denied card / live preview + status line), wake lock while
   foreground, click delivery via the helper-connection pattern.
4. **Packaging**: camera.oxp staged + signed at build time
   (manifest declares camera.read; install binds it deny; the
   camera-app selftest flips the user grant after observing the
   refusal — the on-device shape of install-binds-deny, user
   consents).
5. **Indicator**: ox-status's card window polls camerad and commits
   the CAM chip on activity (journaling status-cam-active /
   status-cam-inactive) — the privacy signal lives on a surface the
   camera app does not own.
6. **Verification** (`tools/camera-app-gate.sh` ALL GREEN): install →
   tile tap → launch → viewfinder refused (bound deny) → grant →
   viewfinder live (6 frames) → status-card CAM active → shutter
   capture REAL frame colors=8 → Close → intentd reap → indicator
   cleared.

## Instructive findings

1. **The dynamic-tile geometry is load-bearing.** A fifth built-in
   tile would collide with the shell's footer and shift the dynamic
   grid that four green gates tap by coordinate. Shipping the Camera
   as a package reuses the proven dynamic-tile flow instead — and is
   the charter-correct shape anyway: apps are packages.
2. **Gate sequencing raced user consent.** The selftest grants as
   soon as it observes the viewfinder refusal, so a separate
   "shutter-while-denied" tap was a coin flip: the tap landed after
   the grant and the capture SUCCEEDED (the window-raise log proved
   the click routing was fine all along). The frame refusal is the
   deny evidence; the redundant leg is gone.
3. **cfg-attribute theft**: inserting `pub fn b64_encode` between
   `#[cfg(test)]` and `mod tests` made the attribute apply to the
   FUNCTION — compiling it out of release builds ("cannot find
   function b64_encode"). Attributes bind to the next item; watch
   what you insert in front of.
4. Three more compile-time catches by workspace-test before any boot:
   a Result matched with a None arm, the removed fake_frame alias,
   and a base64 test vector with the wrong length.

## Honest scope

- The viewfinder is ~1 FPS at 160×120 under TCG (frame IPC + full
  window re-commit); streaming mmap + damage-tracked partial commits
  are the next camera work. The hardware privacy shutter remains
  hardware-scope; the in-use indicator is live.
- The CAM chip lives on the status card; a system-wide top-bar chip
  lands with the shell top-bar rework.

## What this unlocks

- Every pixel-ish UI need (photos, maps tiles, charts) now has a
  blit primitive + IPC shape.
- On hardware: the same app + daemon against a real sensor; the
  virtual gate is the bring-up checklist.
