#!/usr/bin/env python3
"""Amend the LUKS2 board row: guest unlock now proven in-guest; R-23
blocker sharply characterized (no skcipher allocatable in guest)."""

path = "README-PHASE1.md"
with open(path, "r", encoding="utf-8", newline="") as f:
    text = f.read().replace("\r\n", "\n")

old = "| LUKS2 data-at-rest | **implemented + host-validated** (volume key == cryptsetup); guest table-load blocked by R-23 env anomaly, graceful fallback active | luks-selftest in suite |"
new = "| LUKS2 data-at-rest | **implemented + host- and guest-validated** (unlock digest validated in-guest; keyfile-newline bug fixed); table load still blocked by R-23: guest allocates no skcipher at all (probed 4 ciphers) — reports/2026-09-01-luks-data-volume.md | luks-selftest in suite |"
assert text.count(old) == 1, text.count(old)
with open(path, "w", encoding="utf-8", newline="") as f:
    f.write(text.replace(old, new))
print("board row amended")
