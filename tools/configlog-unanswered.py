#!/usr/bin/env python3
"""List every kconfig symbol the nixpkgs config merge asked WITHOUT a
default answer (the interactive-EOF flood), with its chosen location.
Feeds the fragment fix: each NAME needs a pinned answer in
kernel/fragments/pinephone-pro.config (usually =n for gadget legacy)."""
import re

pat = re.compile(r"^QUESTION:.*NAME: ([A-Za-z0-9_]+), ALTS: ([^,]*), ANSWER: (.*)$")
unanswered = []
last_desc = ""
with open("/tmp/ppp-configlog.txt") as f:
    for line in f:
        m = pat.match(line.rstrip("\n"))
        if m:
            sym, alts, ans = m.group(1), m.group(2), m.group(3)
            if ans == "" or ans.strip() == "":
                unanswered.append(sym)
            else:
                last_desc = sym
print("unanswered count:", len(unanswered))
print("symbols:")
for s in unanswered:
    print(s)
