#!/usr/bin/env python3
"""
K8s metrics sampler: every INTERVAL seconds record node (loadavg, mem, CPU), per-pod (RSS, CPU),
and events (OOMKilled, restarts). Writes JSONL to results/metrics.jsonl.
Run from a machine with kubectl configured (e.g. during ramp load test).
Usage:
  python metrics_sampler_k8s.py --namespace matrix-qa --interval 2 --output results/metrics.jsonl
  (SIGTERM/SIGINT to stop)
"""
import argparse
import json
import subprocess
import sys
import time
from pathlib import Path


def run_kubectl(*args: str, namespace: str | None = None) -> str | None:
    cmd = ["kubectl"] + list(args)
    if namespace and "-n" not in args and "--all-namespaces" not in args:
        cmd.extend(["-n", namespace])
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if r.returncode == 0:
            return r.stdout
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return None


def get_node_metrics(namespace: str | None) -> dict:
    """kubectl top node (requires metrics-server)."""
    out = run_kubectl("top", "node", "--no-headers")
    if not out:
        return {}
    # Format: "node-name   cpu%   mem%"
    lines = out.strip().split("\n")
    if not lines:
        return {}
    total_cpu = total_mem = 0.0
    for line in lines:
        parts = line.split()
        if len(parts) >= 3:
            try:
                total_cpu += float(parts[1].replace("%", ""))
                total_mem += float(parts[2].replace("%", ""))
            except ValueError:
                pass
    return {"node_cpu_pct": round(total_cpu, 2), "node_mem_pct": round(total_mem, 2)}


def get_pods_metrics(namespace: str) -> list[dict]:
    """kubectl top pods -n NAMESPACE (CPU, memory)."""
    out = run_kubectl("top", "pods", "--no-headers", namespace=namespace)
    if not out:
        return []
    rows = []
    for line in out.strip().split("\n"):
        if not line:
            continue
        parts = line.split()
        if len(parts) >= 3:
            try:
                rows.append({
                    "pod": parts[0],
                    "cpu_m": parts[1].replace("m", "") if "m" in parts[1] else str(int(float(parts[1].replace("%", "")) * 10)),
                    "mem_mi": parts[2].replace("Mi", "").replace("MiB", "") if "Mi" in parts[2] or "MiB" in parts[2] else parts[2],
                })
            except (ValueError, IndexError):
                pass
    return rows


def get_pods_restarts_oom(namespace: str) -> tuple[list[dict], int]:
    """kubectl get pods -o json: restart counts and OOMKilled. Returns (per-pod list, oom_count)."""
    out = run_kubectl("get", "pods", "-o", "json", namespace=namespace)
    if not out:
        return [], 0
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return [], 0
    oom_count = 0
    pods = []
    for item in data.get("items", []):
        name = item.get("metadata", {}).get("name", "")
        statuses = item.get("status", {}).get("containerStatuses") or []
        restarts = 0
        for cs in statuses:
            restarts += cs.get("restartCount", 0)
            last = cs.get("lastState", {}).get("terminated", {})
            if last.get("reason") == "OOMKilled":
                oom_count += 1
        pods.append({"pod": name, "restarts": restarts})
    return pods, oom_count


def get_events_oom(namespace: str) -> int:
    """Count OOMKilled events in namespace (recent)."""
    out = run_kubectl("get", "events", "--sort-by=.lastTimestamp", "-o", "json", namespace=namespace)
    if not out:
        return 0
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return 0
    count = 0
    for item in data.get("items", []):
        if item.get("reason") == "OOMKilled":
            count += 1
    return count


def sample(namespace: str) -> dict:
    ts = time.time()
    node = get_node_metrics(namespace)
    pods_top = get_pods_metrics(namespace)
    pods_restarts, oom_pods = get_pods_restarts_oom(namespace)
    oom_events = get_events_oom(namespace)
    # Merge pod metrics with restarts
    pod_map = {p["pod"]: {**p, "restarts": 0} for p in pods_top}
    for p in pods_restarts:
        if p["pod"] in pod_map:
            pod_map[p["pod"]]["restarts"] = p["restarts"]
        else:
            pod_map[p["pod"]] = {"pod": p["pod"], "cpu_m": "", "mem_mi": "", "restarts": p["restarts"]}
    return {
        "ts_sec": round(ts, 2),
        "node": node,
        "pods": list(pod_map.values()),
        "oom_kills_pods": oom_pods,
        "oom_kills_events": oom_events,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="K8s metrics sampler for load-test harness")
    parser.add_argument("--namespace", default="matrix-qa", help="K8s namespace")
    parser.add_argument("--interval", type=int, default=2, help="Sample interval (seconds)")
    parser.add_argument("--output", default="results/metrics.jsonl", help="Output JSONL path")
    args = parser.parse_args()

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    print(f"Sampling every {args.interval}s into {out_path} (namespace={args.namespace}). Stop with Ctrl+C.", file=sys.stderr)
    while True:
        try:
            row = sample(args.namespace)
            with open(out_path, "a") as f:
                f.write(json.dumps(row) + "\n")
        except KeyboardInterrupt:
            break
        except Exception as e:
            print(f"Sample error: {e}", file=sys.stderr)
        time.sleep(args.interval)
    return 0


if __name__ == "__main__":
    sys.exit(main())
