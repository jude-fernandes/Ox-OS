#!/usr/bin/env python3
"""Chunk 67: add the exit-code journal to every direct-exec daemon run
file (the chunk-63 oxcom pattern, fleet-wide). A daemon that dies before
its first milestone currently vanishes silently; after this, every death
self-reports `NAME: exited rc=<N>` on the kernel ring.

Only rewrites files whose final line is exactly `exec /usr/bin/<bin>
[args]`; idempotent (files already carrying the journal are skipped).
The journal name strips the `ox-` prefix (kmsg lines already use the
leaf: `lockd: OXMILESTONE ...`)."""
import re
import sys
from pathlib import Path

SRC = Path("/root/oxbuild/system/s6-rc-source")
PAT = re.compile(r"^exec (/usr/bin/[a-z][a-z0-9-]*)(.*)$", re.M)


def journal_name(binpath: str) -> str:
    leaf = binpath.rsplit("/", 1)[-1]
    return leaf[3:] if leaf.startswith("ox-") else leaf


def main() -> int:
    changed, skipped = [], []
    for run in sorted(SRC.glob("*/run")):
        text = run.read_text()
        if "exited rc=" in text:
            skipped.append(run.parent.name)
            continue
        m = PAT.search(text)
        if not m:
            skipped.append(run.parent.name + " (shape)")
            continue
        binp, args = m.group(1), m.group(2).rstrip()
        name = journal_name(binp)
        block = (
            f"{binp}{args}\n"
            f'RC=$?\n'
            f'echo "<6>{name}: exited rc=$RC" > /dev/kmsg 2>/dev/null || true\n'
            f'exit "$RC"'
        )
        text = text[: m.start()] + block + text[m.end():]
        run.write_text(text)
        changed.append(run.parent.name)
    print("CHANGED:", " ".join(changed))
    print("SKIPPED:", " ".join(skipped))
    return 0


if __name__ == "__main__":
    sys.exit(main())
