# Durable payment receipts (milestone report)

Date: 2026-08-30
Scope: paymentsd records every authorized payment to the persistent data
volume and serves the receipt list over IPC; the boot gate proves the whole
chain on the real payload.

## What exists now

| Piece | File | Notes |
| --- | --- | --- |
| Receipt store | `rust/crates/oxpaymentsd/src/main.rs` | `record_receipt()` appends one JSON line per authorized payment to `$OX_DATA_DIR/receipts.jsonl` (default `/data/ox/receipts.jsonl`); `read_receipts()` lists them. |
| IPC op | same | `list_receipts` returns the parsed receipt array. |
| Write point | same | confirm path of the confirmation card, after the `payment-authorized` milestone, emits `OXMILESTONE name=receipt-recorded file=...`. |
| Demo listing | `rust/crates/oxctl/src/main.rs` | `paydemo` polls `list_receipts` until the payment lands, then prints `ox-pay receipts: {...}` to the console. |
| Wake lock | same | paymentsd holds a powerd wake lock for the lifetime of a confirmation card (`WakeGuard` releases on every exit path). A pending payment must not be interrupted by idle doze. |
| Host tests | same | `receipts_record_and_list` round-trips the store (9/9 tests pass). |

## Defects found and fixed on the way

1. **`/data` was never mounted in the Nix QEMU path.** The payload's
   `data.img` shipped as 256 MiB of zeros — nothing ever formatted it — so
   stage 2's plain-mount fallback failed and every write to `/data` hit the
   read-only rootfs (`EROFS os error 30`). `run-qemu.sh` now puts an ext4
   signature on the image once before attaching (kernel already has
   `CONFIG_EXT4_FS=y`; verified in the realized configfile).
2. **Idle doze could kill a pending payment.** With no activity source the
   idle clock starts at boot, so autosuspend fired mid-confirmation
   (`pm-autosuspend ... locks=0`) and the machine froze under the card.
   Fixed in the product, not the gate: paymentsd now holds a wake lock
   while the card is up.
3. **Key presses during the power self-test freeze are lost.** The boot
   self-test suspends for ~8 s; a scripted key press inside that window
   never reaches the compositor. The pay gate now retries the press after
   resume (the dev powerd window also moved to 300 s so scripted demos do
   not race the idle timer).

## Gate verdict (`tools/pay-gate.sh`, extended)

```
[ox-pay] confirmation card shown:
[ox-pay]   OXMILESTONE name=payment-confirm-shown amount=1250 merchant=cafe.example
[ox-pay] screendump ok
[ox-pay] sent 'a' (accept) [attempt 1]
[ox-pay] sent 'a' (accept) [attempt 2]
[ox-pay] wake lock held during confirmation
[ox-pay] durable receipt:
[ox-pay]   OXMILESTONE name=receipt-recorded file=/data/ox/receipts.jsonl
[ox-pay]   ox-pay receipts: {"amount_minor":1250,"merchant":"cafe.example","reference":null,"ts":1788108576}
[ox-pay] framebuffer 1280x800, lit-pixel ratio 1.0000
[ox-pay] ALL GREEN — tap -> wallet card -> user accept -> authorized -> durable receipt
```

## Honest scope

- Persistence is proven **within one boot** (receipt written to and read
  back from the mounted data volume). A cross-reboot replay gate is the
  natural follow-up — the mechanism (mounted ext4 on `data.img`) now
  supports it.
- The dev data volume is **plain ext4, unencrypted**. The designed path is
  LUKS (`ox-init` already carries the unlock flow and dev passphrase, R-22);
  formatting the dev image through that flow is still open.
- Receipts are plain JSON lines — **not signed**. Sign them with the
  payload key (or a wallet key) before any real-value claim.
- The NDEF tap is still simulated per boot by `paydemo` (as before); one
  decision per card; amounts are minor units with a EUR display default.
- Gate runs on TCG QEMU; no performance claims (R-20).

Artifacts: `docs/process/reports/2026-08-30-payment-receipts.png`
(post-authorization screendump).
