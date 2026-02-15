#!/usr/bin/env python3
"""
Time-sliced metrics: every P seconds query Prometheus (or node_load1) and append to a CSV/JSONL file.
Started by run_load_test when --collect-metrics; stops when process is terminated.
"""
import argparse
import json
import os
import sys
import time
from pathlib import Path

import requests
import yaml


def load_config(config_path: str) -> dict:
    with open(config_path) as f:
        return yaml.safe_load(f)


def get_load1(prometheus_url: str) -> float | None:
    if not prometheus_url:
        return None
    try:
        r = requests.get(
            f"{prometheus_url.rstrip('/')}/api/v1/query",
            params={"query": "node_load1"},
            timeout=5,
        )
        r.raise_for_status()
        data = r.json()
        results = data.get("data", {}).get("result", [])
        if not results:
            return None
        return float(results[0].get("value", [None, None])[1])
    except Exception:
        return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="config.yaml")
    parser.add_argument("--interval", type=int, default=10)
    parser.add_argument("--output", default="metrics.jsonl", help="Output file (JSONL: ts_sec, load1)")
    args = parser.parse_args()

    if not os.path.isfile(args.config):
        print(f"Error: {args.config} not found", file=sys.stderr)
        return 1

    config = load_config(args.config)
    prometheus_url = (os.environ.get("PROMETHEUS_URL") or (config.get("safety") or {}).get("prometheus_url") or "").strip()
    script_dir = Path(__file__).resolve().parent
    out_path = Path(args.output)
    if not out_path.is_absolute():
        out_path = script_dir.parent / out_path

    while True:
        ts = time.time()
        load1 = get_load1(prometheus_url)
        row = {"ts_sec": ts, "load1": load1}
        with open(out_path, "a") as f:
            f.write(json.dumps(row) + "\n")
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
