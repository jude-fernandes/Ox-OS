# Receipt persistence across power cycle — DONE (gate ALL GREEN)

Date: 2026-08-30
Gate: `tools/receipts-persist-gate.sh` — boot 1 records a payment receipt
on the data volume, the VM is hard power-cycled with the same `data.img`,
boot 2 must list the old receipt back alongside its own.

## Gate verdict

```
[ox-pay] ALL GREEN — tap -> wallet card -> user accept -> authorized -> durable receipt
[ox-persist] boot-1 receipt ts=1788128912
[ox-persist] flush margin before power-off
[ox-persist] sent 'a' [attempt 2]
[ox-persist] boot 2 listing: ox-pay receipts: [
  {"amount_minor":1250,"merchant":"cafe.example","reference":null,"ts":1788128912},
  {"amount_minor":1250,"merchant":"cafe.example","reference":null,"ts":1788128965}]
[ox-persist] ALL GREEN — receipt survived the power cycle (boot-1 ts=1788128912 listed in boot 2; 2 receipts)
RECEIPT PERSISTENCE MILESTONE COMPLETE
```

Storage-layer proof: boot 2 mounts the same image with
`EXT4-fs (vdc): recovery complete` + `mounted ... r/w` (journal replay of
the hard power-off), and the boot-1 receipt line is still in the file.

## Three real defects the gate exposed and fixed

1. **Focus steal (the multi-day bug).** inputd's dev console grabbed focus
   unconditionally at boot ("focus is ours to claim"), so whenever it
   started after the payment card, every key routed to the console and the
   card timed out — a nondeterministic failure depending purely on service
   start order. Fix (product rule): oxcom's `window-focus` accepts
   `steal:false` — a *polite* focus refused while another window holds
   focus (`polite_focus_granted`, unit-tested in `polite_focus_never_steals`);
   inputd now requests politely; a real app's explicit focus always wins.
2. **Receipts were not durable.** `record_receipt` trusted the ext4 journal
   commit interval; a power-off right after the payment lost the record.
   Now `sync_all()` flushes every payment through the journal.
3. **Demo poll false-positive.** `paydemo` accepted any receipt with a
   matching amount, so in boot 2 it exited on the boot-1 receipt before its
   own payment was accepted. It now baselines the receipt count before the
   tap and waits for the count to grow.

## Honest scope

- The dev data volume is plain ext4; the LUKS formatting flow (R-22 dev
  passphrase) is the designed path and stays open.
- Receipts are plain JSON lines — unsigned. Sign before any real-value claim.
- The tap is still simulated per boot by `paydemo`; one decision per card;
  gate runs on TCG QEMU (R-20: no performance claims).
- inputd's key-echo console is silent while any app holds focus (by design
  now); user-driven focus (click-to-raise) is the later product step.
