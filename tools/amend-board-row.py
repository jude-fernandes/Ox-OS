#!/usr/bin/env python3
"""Amend the receipts board row: persistence gate ALL GREEN."""

path = "README-PHASE1.md"
with open(path, "r", encoding="utf-8", newline="") as f:
    text = f.read().replace("\r\n", "\n")

old_row = "| Durable payment receipts (`/data/ox/receipts.jsonl`) + wake lock during confirmation | SINGLE-BOOT GREEN; cross-boot replay blocked by key-delivery bug (window focus stolen at boot) — see reports/2026-08-30-receipt-persistence.md |"
new_row = "| Durable payment receipts (`/data/ox/receipts.jsonl`, fsynced) + wake lock during confirmation + polite focus rule | DONE (gate: receipt survives VM power cycle; boot-1 receipt listed back in boot 2) |"
assert text.count(old_row) == 1, text.count(old_row)
with open(path, "w", encoding="utf-8", newline="") as f:
    f.write(text.replace(old_row, new_row))
print("board row amended")
