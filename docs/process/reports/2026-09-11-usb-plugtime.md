# USB: plug-time safety (kernel-default quarantine) — chunk 46, Phase 4, 2026-09-11

## Claim

The chunk-44 quarantine had a hole: ox-usbd polled every 500 ms, so a
newly enumerated device was briefly BOUND — in the chunk-44 gate the
usb-storage driver claimed the stick 0.26 s after enumeration, before
any quarantine. Chunk 46 closes the race by moving the default into
the kernel: `usbcore.authorized_default=0` on the kernel cmdline
(the param exists on usbcore since forever; verified in the built
kernel's modinfo before relying on it). Now a hot-plugged stick
enumerates ALREADY unauthorized — the kernel never configures it, no
driver ever binds, and usb-storage first appears only when the
system's authorize flips the switch. The timestamps prove it:
enumeration + kernel quarantine at t=25.76 (journal `default=true`),
first usb-storage detection at t=40.2 — after the selftest's
authorize. ox-usbd stays the policy surface (device list, authorize)
and its journal now records WHO enforced the quarantine
(`default=true` = kernel policy, `default=false` = daemon write), and
a failed enforcement is journaled `usb-quarantine-failed` rather than
ever being reported as quarantined.

## Stack layers (all gated)

1. **Kernel cmdline** (build-payload.sh):
   `usbcore.authorized_default=0` appended to every payload — one
   line, zero kernel rebuild (the param rides the existing builtin
   usbcore).
2. **Daemon** (ox-usbd): quarantine semantics updated — devices
   arriving unauthorized are kernel-default quarantined (journal
   `default=true`); devices arriving authorized still get the daemon
   write (journal `default=false`); a failed write journals
   `usb-quarantine-failed` and the device's cached state keeps the
   TRUTH (authorized), never a comfortable lie. The `authorize`
   op is unchanged (kernel re-probes on authorized=1).
3. **Selftest** (usb-selftest): asserts the cmdline
   (`usb-default-unauthorized` milestone, grepping /proc/cmdline)
   before anything else.
4. **Gate** (usb-gate.sh): unchanged flow, new assertion — and still
   ALL GREEN: hot-plug -> enumerated unauthorized -> no driver ever
   binds -> no blockdev -> usb.read matrix -> authorize -> blockdev
   appears -> clean unplug.

## Instructive findings

1. **The one-line fix and the one-line bug share a shape.** The
   quarantine refactor had to keep the chunk-44 rule (reported state
   = enforced state) under a new branch: with the kernel default
   doing the enforcement, "arrived unauthorized" and "daemon wrote
   unauthorized" are different facts, and a failed write must leave
   the record TRUE (authorized) and journal the failure — the first
   draft overwrote the flag unconditionally, which would have
   reported an unenforceable device as quarantined.
2. **Check the parameter exists before shipping the cmdline.** The
   param name came from memory; the built kernel's
   modules.builtin.modinfo (NUL-separated — `tr '\0' '\n'` before
   grepping) confirms `usbcore.parm=authorized_default:...` with the
   exact value semantics (0/1/2/-1). Value 2 ("authorized for
   internal devices") is the hardware-path evolution: whitelist the
   internal USB devices, keep everything external quarantined.
3. **Timestamps close races as evidence.** "No block device while
   quarantined" (chunk 44) did not prove the race was closed — the
   driver may have bound and unbound. The closed-race proof is
   temporal: driver detection at t=40.2 vs enumeration at t=25.76,
   with the authorize in between. Negative claims need their own
   positive evidence.

## Honest scope

- Value 0 quarantines ALL new USB devices; there are no internal USB
  devices on this target, so nothing legitimate is caught. Hardware
  targets with internal USB (touch, modems) move to
  `authorized_default=2` + an internal-device list.
- The enumeration-to-visibility ordering is now the kernel's, but a
  quarantined device is still ENUMERATED (its descriptors are
  readable in sysfs — identity, not payload). Descriptor-level
  privacy is not a thing; payload access remains the boundary.
- ox-usbd's poll is now redundant-but-harmless (belt and braces for
  boots without the cmdline param); the daemon also still can't
  authorize devices it hasn't seen — unchanged from chunk 44.

## Verification artifacts

- Gate: `tools/usb-gate.sh` (+ `-run.sh`) — USB GATE ALL GREEN;
  zero stray QEMU.
- Serial evidence: `usb-default-unauthorized` (cmdline),
  `usb-added` at t=25.757, `usb-quarantined ... default=true` at
  t=25.759 (kernel enforcement), first `usb-storage 2-1:1.0`
  detection at t=40.2 — after the authorize;
  `usb-authorized-blockdev dev=2-1`, `usb-removed dev=2-1`.
- Full matrix unchanged and green (deny/fake/grant over the real
  device list).
