#!/usr/bin/env python3
"""Parse Ox OS boot logs: OXMILESTONE name=<n> tms=<seconds> lines -> report."""
import argparse
import re
import sys

LINE = re.compile(r"OXMILESTONE name=([A-Za-z0-9_-]+) tms=([0-9.]+)")


def parse(text: str) -> list[tuple[str, float]]:
    out = []
    for m in LINE.finditer(text):
        out.append((m.group(1), float(m.group(2))))
    if not out:
        print("boottime-parse: no milestones found", file=sys.stderr)
        sys.exit(2)
    return out


def main() -> int:
    p = argparse.ArgumentParser(prog="boottime-parse")
    p.add_argument("logfile")
    p.add_argument("--max-total", type=float, default=None,
                   help="fail if first->last exceeds N seconds")
    p.add_argument("--budget", action="append", default=[],
                   help="name=seconds cap for a milestone delta")
    args = p.parse_args()

    with open(args.logfile, "r", encoding="utf-8", errors="replace") as f:
        events = parse(f.read())

    t0 = events[0][1]
    rows, caps = [], dict(b.split("=", 1) for b in args.budget)
    failures = []
    prev_name, prev_t = events[0]
    for name, t in events:
        delta_ms = (t - t0) * 1000.0
        step_ms = (t - prev_t) * 1000.0
        rows.append((name, t - t0, delta_ms, step_ms))
        if name in caps and step_ms > float(caps[name]) * 1000.0:
            failures.append(
                f"{name}: step {step_ms:.0f}ms > budget {caps[name]}s")
        prev_name, prev_t = name, t
    total_s = events[-1][1] - t0
    if args.max_total is not None and total_s > args.max_total:
        failures.append(f"total {total_s:.2f}s > max {args.max_total}s")

    print(f"{'milestone':<24}{'t(s)':>10}{'total(ms)':>12}{'step(ms)':>10}")
    for name, rel, total, step in rows:
        print(f"{name:<24}{rel:>10.3f}{total:>12.0f}{step:>10.0f}")
    print(f"TOTAL {total_s:.2f}s")

    if failures:
        for f_ in failures:
            print(f"BOOTTIME FAIL: {f_}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
