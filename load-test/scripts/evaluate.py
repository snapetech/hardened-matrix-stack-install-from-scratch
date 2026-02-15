#!/usr/bin/env python3
"""
Read metrics file (JSONL from collect_metrics.py) and apply simple pass/fail rules.
Exit 0 = pass, 1 = fail (e.g. max load1 exceeded threshold).
"""
import argparse
import json
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--metrics", default="metrics.jsonl", help="JSONL from collect_metrics.py")
    parser.add_argument("--max-load1", type=float, default=2.0, help="Fail if any load1 > this")
    args = parser.parse_args()

    max_load = None
    try:
        with open(args.metrics) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                row = json.loads(line)
                load1 = row.get("load1")
                if load1 is not None:
                    if max_load is None or load1 > max_load:
                        max_load = load1
    except FileNotFoundError:
        print(f"Metrics file not found: {args.metrics}", file=sys.stderr)
        return 1

    if max_load is None:
        print("No load1 data in metrics", file=sys.stderr)
        return 1

    if max_load > args.max_load1:
        print(f"FAIL: max load1 {max_load} > {args.max_load1}", file=sys.stderr)
        return 1
    print(f"PASS: max load1 {max_load} <= {args.max_load1}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
