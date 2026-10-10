# Telephony: call control + Dialer app — chunk 37, Phase 4, 2026-09-09

## Claim

Ox OS places and ends REAL voice calls through the modem slot, under
the honest-permission contract, from a tappable Dialer app:
oxmodemd gains permission-checked dial/hangup ops (the raw AT path
still refuses call setup by design — dialing only happens through the
policy-gated surface), the AT emulator answers ATD/ATH and logs every
radio dial, and the Dialer app — a signed .oxp package like the
Camera — draws a number pad whose calls are REFUSED while
telephony.dial is bound deny, then dial for real once the user
grants: the emulator's log shows the radio receiving ATD+15550001; —
and ATH on hang-up. Fake mode places a SYNTHETIC call the radio never
sees. The shell's dynamic grid grew to four slots to carry the
growing app set, and the three tile-coordinated gates were re-proven
at the new geometry.

## Stack layers (all gated)

1. **Radio (emulator)**: modem-emu.py answers `ATD<number>;` (logs
   CALL-DIAL), `ATH`/`AT+CHUP` (logs CALL-END) and `AT+CLCC`.
2. **Service** (oxmodemd): `dial {app, number}` consults permstored
   `telephony.dial` (fail-closed) — deny refused, fake = local call
   state the radio never sees, grant = `ATD…;` through the egress-
   journaled engine; `hangup` symmetric (ATH); `callstatus` reports
   state. E.164 validation shared with SMS. The command gate keeps
   refusing ATD on the raw `cmd` op.
3. **App** (ox-dialer, signed dialer.oxp, manifest binds
   telephony.dial=deny on install): number pad (drain-then-draw input
   loop), Call/End, honest states — refused dial surfaces the denial,
   fake calls are labeled SYNTHETIC, granted calls show in-call.
4. **Grid capacity**: dynamic tiles are now 88px tall in two rows —
   four packages visible, all above the footer (test-pinned).
5. **Verification**: dialer-app-gate ALL GREEN (install → tile →
   pad → dial refused (bound deny) → grant → radio dial confirmed in
   the EMULATOR log (`CALL-DIAL to +15550001`) → End → radio
   `CALL-END` → Close → reap), plus re-proofs of tiles-gate,
   grid-event-gate and uninstall-gate at the new geometry.

## Instructive findings

1. **collect_final consumes the final OK.** oxmodemd's AT engine
   returns only the lines BEFORE the terminator (error finals are
   kept, OK is not), so a success check of `lines contains OK` is
   always false — the first real dial was misread as "rejected by
   modem". Success = an Ok result containing NO error final.
2. **One redraw per input event starves the click hub at pad speed.**
   Drawing after every digit (~1s per commit under TCG) let the
   bounded click queue overflow and drop the Call tap — the same
   lesson ox-term learned for keystrokes, now applied as
   drain-the-queue, apply-all, draw-once.
3. **A keep-awake tap loop and app UIs do not mix.** The gates'
   (4,4) activity taps hit the shell's top-left switcher zone and
   raised the shell ABOVE the app window mid-flow, silently
   rerouting every later click to the shell (proven by window-raise
   id=2 at the exact tap coordinates). App gates no longer run one:
   the lock screen and foreground apps hold wake locks, so synthetic
   activity is unnecessary once unlocked.
4. **Install-order races shift dynamic-tile slots.** With Camera and
   Dialer boot-installed, grid-selftest's early Gridtest install
   stole slot 2 between a gate's unlock and its tap (proven by
   `shell-launch app=Gridtest` at the Hello tap). Gridtest now
   installs at unlock+75s — after every other gate's tap window,
   while grid-event-gate (which synchronizes on the install event)
   is unaffected.
5. **Sorted UI rows move as packages accumulate.** The Apps panel's
   Hello row moved from 0 to 2 (Camera, Dialer sort first); the
   uninstall gate's fixed row-0 tap was removing Camera. Rows are
   84px apart from screen y=236; the gate now targets row 2.

## Honest scope

- One call at a time, MO only, no ring/answer path yet (MT calls
  need RING/CLCC URC handling in the daemon and emulator).
- No in-call audio routing (the audio chunk's sink exists; a
  call-audio loop is future work). Messaging app is a separate
  chunk (SMS transport is already gated).
- Fake mode is a PRIVACY feature (UI works, network never sees the
  number) — clearly labeled, journaled synthetic.

## What this unlocks

- Messaging app over the same IPC (SMS transport already gated).
- MT-call path + in-call UI on the way to the fleet's scripted
  call tests; on hardware the same daemon talks to the real modem.
