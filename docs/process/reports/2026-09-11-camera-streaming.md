# Camera: the streaming I/O method — chunk 47, Phase 4, 2026-09-11

## Claim

ox-camerad captures through the standard V4L2 STREAMING path —
REQBUFS(4, MMAP) + QUERYBUF/mmap + QBUF + STREAMON, frames dequeued
with DQBUF and requeued — replacing the legacy per-frame read()
open/capture/close cycle. The session lives for the daemon's
lifetime (opened once, journaled `camera-streaming-on method=mmap
buffers=4`), errors tear it down and the next grab reopens clean.
The whole honest-permission contract is untouched and both camera
gates re-proved GREEN: the HAL gate's real captures still pin
vivid's 8-bar color strip (colors=8), and the app gate's full UI
lifecycle (signed package, bound-deny refusal, grant, live
viewfinder, status indicator, real capture, reap) runs on the
streaming daemon.

## Stack layers (all gated)

1. **ABI** (probe-verified, unit-pinned): REQBUFS 0xc0145608,
   QUERYBUF 0xc0585609, QBUF 0xc058560f, DQBUF 0xc0585611, STREAMON
   0x40045612, STREAMOFF 0x40045613; v4l2_requestbuffers = 20 bytes,
   v4l2_buffer = 88 bytes (timeval's 8-alignment puts the timestamp
   at 24 and the m.offset union at 64 — index@0, type@4, bytesused@8,
   flags@12, memory@60, length@72).
2. **Daemon** (ox-camerad): StreamSession owns fd + mapped buffers
   (`unsafe impl Send` — pointers are only used through the
   mutex-guarded Cam); grab() dequeues (blocking), copies out clamped
   to the mapped length, requeues; Drop does STREAMOFF + munmap +
   close; capability check now requires CAP_STREAMING (not
   READWRITE); a grab error drops the session and the next grab
   reopens fresh (`camera-streaming-on … opened=N` counts reopeners).
3. **Permission layer**: untouched — deny/fake/grant exactly as
   before (the streaming session is the driver layer's business;
   policy still consults permstored per capture/frame op).
4. **Verification**: camera-gate ALL GREEN (colors=8 real captures
   over streaming, deny/fake/grant matrix) + camera-app-gate ALL
   GREEN (viewfinder frames + shutter capture + indicator over
   streaming); workspace tests green (new ABI numbers + struct
   layout + zeroed-buffer invariants).

## Instructive findings

1. **STREAMON/STREAMOFF take the buffer TYPE, not a zero.** The first
   run passed `int 0` — the natural-looking "start" value — and got
   EINVAL from vivid: the argument is a pointer to
   `enum v4l2_buf_type` (1 = VIDEO_CAPTURE). An argument of the
   wrong VALUE failed exactly where an argument of the wrong TYPE
   would; the ioctl number was right, the ABI contract still wasn't.
   The probe checked the numbers; only the gate could check the
   semantics.
2. **The ABI probe pays for itself every time.** All six ioctl
   numbers and both struct layouts came from a 20-line C program
   against linux/videodev2.h, and live on as compile-time constants
   pinned by unit tests. Deriving _IOWR encodings by hand is how the
   32-bit-compat mistake (chunk 36) happens; the probe plus pinned
   asserts makes it impossible to repeat silently.
3. **`*mut u8` in a shared struct needs a stated story.** Cam lives
   in an Arc<Mutex<>> that crosses into the IPC closure, so the
   mapped-buffer pointers made the daemon un-Send. The honest fix is
   the one-line `unsafe impl Send` with its invariant written down:
   the pointers are driver mappings used only through the mutex.
   Replacing them with usize (the cowardly alternative) would have
   kept the compiler quiet and the invariant undocumented.
4. **Sessions beat snapshots for streaming devices.** The old
   open-capture-close cycle re-ran S_FMT every frame; the session
   keeps the sensor streaming continuously and grabs from the queue —
   which is also what makes reopen-on-error safe (the Drop fully
   unwinds the stream, so a fresh open starts clean).

## Honest scope

- Under TCG the viewfinder is still ~1 FPS (the emulator, not the
  I/O method, dominates); the streaming path removes the per-frame
  setup cost that would dominate on hardware.
- Four buffers, non-multiplanar (V4L2_BUF_TYPE_VIDEO_CAPTURE), BGR24
  only; no USERPTR/DMA-BUF memory, no explicit frame-rate
  negotiation (par=0), no timestamp-based scheduling.
- Session reopen-on-error is fresh-open only; a persistent sensor
  fault surfaces as repeated open errors in the journal.
- The DQBUF is blocking — a stopped sensor would block the daemon's
  IPC thread inside the mutex. vivid always produces frames; real
  hardware would want O_NONBLOCK + poll (noted for the hardware
  port).

## Verification artifacts

- Gates: `tools/camera-gate.sh` ALL GREEN (real capture colors=8,
  deny/fake/grant) + `tools/camera-app-gate.sh` ALL GREEN (signed
  package, bound-deny refusal, grant, live viewfinder, CAM
  indicator, real capture, reap); zero stray QEMU.
- Serial: `camera-streaming-on method=mmap buffers=4 opened=1` at
  t=33.7, `camera-real-captured colors=8`.
- Workspace tests: ioctl numbers (6), struct layouts (20/88 bytes),
  zeroed-buffer invariants.
