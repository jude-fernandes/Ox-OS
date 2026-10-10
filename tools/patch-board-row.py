#!/usr/bin/env python3
"""Insert the receipts board row after the payment-UI row in README-PHASE1."""

path = "README-PHASE1.md"
with open(path, "r", encoding="utf-8", newline="") as f:
    lines = f.read().replace("\r\n", "\n").split("\n")

row = None
for i, line in enumerate(lines):
    if "Payment confirmation UI" in line:
        row = i
        break
assert row is not None, "payment-UI row not found"
lines.insert(
    row + 1,
    "| Durable payment receipts (`/data/ox/receipts.jsonl`) + wake lock during confirmation | DONE (gate: tap -> card -> accept -> authorized -> receipt listed back) |",
)
with open(path, "w", encoding="utf-8", newline="") as f:
    f.write("\n".join(lines))
print(f"board row inserted after line {row + 1}")
