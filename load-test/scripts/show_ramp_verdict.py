#!/usr/bin/env python3
"""Print verdict from last k8s ramp (results/ramp_metrics_summary.json). Run from load-test/ or pass --results-dir."""
import json
import sys
from pathlib import Path


def main() -> int:
    script_dir = Path(__file__).resolve().parent
    load_test_dir = script_dir.parent
    results_dir = load_test_dir / "results"
    summary_path = results_dir / "ramp_metrics_summary.json"
    if not summary_path.exists():
        print(f"No ramp summary at {summary_path}. Run a k8s ramp first.", file=sys.stderr)
        return 1
    with open(summary_path) as f:
        out = json.load(f)
    duration = out.get("duration_s")
    peak_n = out.get("peak_n")
    per = out.get("per_participant") or {}
    ln = out.get("load1_node")
    lstack = out.get("load1_stack_node")
    ll = out.get("load1_local")
    lat = out.get("server_latency_ms")
    baseline = out.get("baseline_load1_node")
    print("--- Last ramp verdict ---")
    if duration is not None:
        print(f"  duration_s: {duration}")
    if peak_n is not None:
        print(f"  peak_n: {peak_n}")
    if per:
        parts = [f"cpu_m={per.get('cpu_m')}", f"mem_mi={per.get('mem_mi')}", f"load1_added_per_user={per.get('load1_added_per_user')}"]
        print(f"  per_participant: {', '.join(str(p) for p in parts if p.split('=')[-1] not in ('None', ''))}")
    if baseline is not None:
        print(f"  baseline_load1_node: {baseline}")
    if ln:
        print(f"  load1_node (client_node): min={ln.get('min')} median={ln.get('median')} max={ln.get('max')}")
    if lstack:
        print(f"  load1_stack_node: min={lstack.get('min')} median={lstack.get('median')} max={lstack.get('max')}")
    if ll:
        print(f"  load1_local (orchestrator): min={ll.get('min')} median={ll.get('median')} max={ll.get('max')}")
    if lat:
        print(f"  server_latency_ms: min={lat.get('min')} median={lat.get('median')} max={lat.get('max')}")
    print(f"  summary: {summary_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
