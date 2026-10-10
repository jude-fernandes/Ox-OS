#!/usr/bin/env python3
"""Chunk 68: give every gate runner the s6 integrity guard (inline —
runners don't source gate-lib). Replaces any partial prior insertion.
Idempotent."""
import sys
from pathlib import Path

TOOLS = Path("/root/oxbuild/tools")
SNIPPET = '''# chunk 68: s6 integrity — fail fast on a partial-tree build (the
# Oct-5 contacts-gate failure: a build raced the tree, the payload's
# s6 DB missed oxcom, and the gate failed hours later on an unrelated
# pattern).
IN_TREE=$(ls system/s6-rc-source | wc -l)
rm -rf /tmp/sqcheck && unsquashfs -q -d /tmp/sqcheck "$P/system.img" >/dev/null 2>&1
IN_IMG=$(ls /tmp/sqcheck/etc/s6-rc/source 2>/dev/null | wc -l)
rm -rf /tmp/sqcheck
echo "S6 INTEGRITY tree=$IN_TREE image=$IN_IMG"
[ "$IN_IMG" -ge "$IN_TREE" ] || { echo "S6 INTEGRITY FAILED — payload incomplete"; exit 1; }
'''


def main() -> int:
    bad = 0
    for run in sorted(TOOLS.glob("*-gate-run.sh")):
        text = run.read_text()
        if "S6 INTEGRITY" in text and 's6_integrity_guard "$P"' not in text:
            print(f"SKIP {run.name}: already guarded")
            continue
        lines = text.splitlines(keepends=True)
        out, inserted = [], False
        for ln in lines:
            out.append(ln)
            if not inserted and (
                ln.startswith('echo "PAYLOAD ')
                or ln.startswith('K="$(sed -n 2p')
            ):
                out.append(SNIPPET)
                inserted = True
        # drop any stale partial call from the earlier sed attempt
        cleaned = "".join(out).replace('s6_integrity_guard "$P"\n', "")
        run.write_text(cleaned)
        if inserted:
            print(f"OK   {run.name}")
        else:
            print(f"MISS {run.name}: no PAYLOAD echo line")
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
