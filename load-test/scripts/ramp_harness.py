#!/usr/bin/env python3
"""
Ramp load-test harness: for N in min_participants..max_participants, run Tier 1 (LiveKit SDK load test),
optionally Tier 2 (Playwright Element Call), collect metrics, write results/summary.csv.
Stop on OOM, join success < 90%%, or RTT/loss threshold.
Usage:
  python ramp_harness.py --config config.yaml --min 2 --max 5 --tier1-duration 180
  KUBECONFIG=~/.kube/config python ramp_harness.py --config config.yaml --namespace matrix-qa ...
"""
import argparse
import csv
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import yaml


def load_config(config_path: str) -> dict:
    with open(config_path) as f:
        return yaml.safe_load(f)


def run_tier1(
    script_dir: Path,
    load_test_dir: Path,
    config_path: str,
    n: int,
    duration: int,
    config: dict,
    start_stagger: float = 0.1,
) -> tuple[int, float]:
    """Run run_load_test.py --participants N --duration D. Returns (exit_code, duration_sec)."""
    start = time.monotonic()
    env = os.environ.copy()
    env["TEST_ROOM_ID"] = os.environ.get("TEST_ROOM_ID", "")
    python_exe = sys.executable
    venv_py = load_test_dir / ".venv" / "bin" / "python3"
    if venv_py.exists():
        python_exe = str(venv_py)
    cmd = [
        python_exe,
        str(script_dir / "run_load_test.py"),
        "--config", config_path,
        "--no-create-users",
        "--participants", str(n),
        "--duration", str(duration),
        "--start-stagger", str(start_stagger),
    ]
    rc = subprocess.call(cmd, cwd=load_test_dir, env=env)
    elapsed = time.monotonic() - start
    return rc, elapsed


def run_tier1_ramp_up(
    script_dir: Path,
    load_test_dir: Path,
    config_path: str,
    min_n: int,
    max_n: int,
    step_duration: int,
    config: dict,
    start_stagger: float = 0.1,
    k8s_participants: bool = False,
    k8s_namespace: str = "matrix-qa",
    k8s_image: str = "load-test-participant:latest",
    k8s_image_pull_policy: str | None = None,
) -> tuple[int, float]:
    """Run run_load_test.py --ramp-up: single pass, add participants over time. Returns (exit_code, duration_sec)."""
    start = time.monotonic()
    env = os.environ.copy()
    env["TEST_ROOM_ID"] = os.environ.get("TEST_ROOM_ID", "")
    python_exe = sys.executable
    venv_py = load_test_dir / ".venv" / "bin" / "python3"
    if venv_py.exists():
        python_exe = str(venv_py)
    cmd = [
        python_exe,
        str(script_dir / "run_load_test.py"),
        "--config", config_path,
        "--no-create-users",
        "--ramp-up",
        "--min-participants", str(min_n),
        "--max-participants", str(max_n),
        "--step-duration", str(step_duration),
        "--start-stagger", str(start_stagger),
    ]
    if k8s_participants:
        cmd += ["--k8s-participants", "--k8s-namespace", k8s_namespace, "--k8s-image", k8s_image]
        if k8s_image_pull_policy:
            cmd += ["--k8s-image-pull-policy", k8s_image_pull_policy]
    rc = subprocess.call(cmd, cwd=load_test_dir, env=env)
    elapsed = time.monotonic() - start
    return rc, elapsed


def read_load_test_result(load_test_dir: Path) -> tuple[float, int, int]:
    """Read .load_test_result.json if present. Returns (success_rate_pct, joined, total)."""
    path = load_test_dir / ".load_test_result.json"
    if not path.exists():
        return 0.0, 0, 0
    try:
        with open(path) as f:
            data = json.load(f)
        joined = data.get("joined", 0)
        total = data.get("total", 0)
        rate = data.get("success_rate_pct", (100.0 * joined / total) if total else 0)
        return float(rate), joined, total
    except (json.JSONDecodeError, OSError):
        return 0.0, 0, 0


def run_tier2(script_dir: Path, load_test_dir: Path, room_url: str, n: int, duration: int, out_path: Path) -> tuple[int, float | None, float | None]:
    """Run tier2_element_call_playwright.py. Returns (exit_code, avg_rtt_ms, packet_loss_pct)."""
    start = time.monotonic()
    rc = subprocess.call(
        [
            sys.executable,
            str(script_dir / "tier2_element_call_playwright.py"),
            "--room-url", room_url,
            "--participants", str(n),
            "--duration", str(duration),
            "--output", str(out_path),
        ],
        cwd=load_test_dir,
    )
    elapsed = time.monotonic() - start
    # Parse last lines of output for avg_rtt and loss (or we could parse webrtc_stats.jsonl)
    return rc, None, None


def aggregate_metrics_jsonl(metrics_path: Path) -> dict:
    """Read metrics.jsonl and return peak_cpu, peak_rss_total, oom_kills, restarts."""
    peak_cpu = 0.0
    peak_rss = 0
    oom_kills = 0
    restarts = 0
    if not metrics_path.exists():
        return {"peak_cpu": 0, "peak_rss_total": 0, "oom_kills": 0, "restarts": 0}
    with open(metrics_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            node = row.get("node") or {}
            cpu = node.get("node_cpu_pct") or 0
            if isinstance(cpu, (int, float)):
                peak_cpu = max(peak_cpu, float(cpu))
            oom_kills = max(oom_kills, row.get("oom_kills_pods", 0) + row.get("oom_kills_events", 0))
            row_rss = 0
            for p in row.get("pods") or []:
                restarts = max(restarts, p.get("restarts", 0))
                try:
                    row_rss += int(str(p.get("mem_mi", "0")).replace("Mi", "").split(".")[0] or 0)
                except (ValueError, TypeError):
                    pass
            peak_rss = max(peak_rss, row_rss)
    return {"peak_cpu": peak_cpu, "peak_rss_total": peak_rss, "oom_kills": oom_kills, "restarts": restarts}


def main() -> int:
    parser = argparse.ArgumentParser(description="Ramp load-test harness (Tier 1 + optional Tier 2, metrics, summary.csv)")
    parser.add_argument("--config", default="config.yaml", help="Load-test config")
    parser.add_argument("--min", type=int, default=2, help="Min participants (inclusive)")
    parser.add_argument("--max", type=int, default=10, help="Max participants (inclusive)")
    parser.add_argument("--tier1-duration", type=int, default=180, help="Tier 1 run duration (seconds)")
    parser.add_argument("--tier2-duration", type=int, default=180, help="Tier 2 run duration (seconds)")
    parser.add_argument("--cooldown", type=int, default=60, help="Cooldown between N steps (seconds)")
    parser.add_argument("--skip-tier2", action="store_true", help="Skip Tier 2 (Playwright)")
    parser.add_argument("--single-pass", action="store_true", help="Single run: ramp up from min to max (add participants over time), one metrics stream")
    parser.add_argument("--start-stagger", type=float, default=0.1, help="Seconds between starting each participant (0 = full parallel; 1c/1g is k8s-only, host can max out)")
    parser.add_argument("--room-url", help="Element Call room URL for Tier 2 (required if not --skip-tier2)")
    parser.add_argument("--namespace", default="matrix-qa", help="K8s namespace for metrics sampler")
    parser.add_argument("--results-dir", default="results", help="Output directory for metrics and summary")
    parser.add_argument("--k8s-participants", action="store_true", help="Run participants as k8s Jobs (in-cluster; no port-forward)")
    parser.add_argument("--k8s-image", default="load-test-participant:latest", help="Participant image when using --k8s-participants")
    parser.add_argument("--k8s-image-pull-policy", default=None, help="e.g. Never when image pre-loaded on node")
    parser.add_argument("--step-duration-min", type=int, default=20, help="Min seconds between adding each participant (default 20; use 10 for faster ramp)")
    parser.add_argument("--safety-interval", type=float, default=1.0, help="Seconds between safety/load checks (default 1)")
    parser.add_argument("--ramp-fast", action="store_true", help="Faster ramp: step-duration-min=10, safety-interval=1")
    args = parser.parse_args()
    if getattr(args, "ramp_fast", False):
        args.step_duration_min = 10
        args.safety_interval = 1.0

    script_dir = Path(__file__).resolve().parent
    load_test_dir = script_dir.parent
    config_path = load_test_dir / args.config
    if not config_path.exists():
        print(f"Config not found: {config_path}", file=sys.stderr)
        return 1
    config = load_config(str(config_path))

    results_dir = load_test_dir / args.results_dir
    results_dir.mkdir(parents=True, exist_ok=True)
    summary_path = results_dir / "summary.csv"
    summary_exists = summary_path.exists()
    join_success_threshold = 90.0
    stop_on_oom = True

    # CSV header
    fieldnames = [
        "n", "mode", "join_success_rate", "peak_cpu", "peak_rss_total",
        "oom_kills", "restarts", "avg_rtt_ms", "packet_loss_pct", "tier1_exit", "notes",
    ]
    with open(summary_path, "a", newline="") as cf:
        w = csv.DictWriter(cf, fieldnames=fieldnames)
        if not summary_exists:
            w.writeheader()

    room_file = load_test_dir / "test_room_id.txt"
    if room_file.exists():
        os.environ["TEST_ROOM_ID"] = room_file.read_text().strip()

    if args.single_pass:
        # Single run: ramp up from min to max (add participants over time), one metrics stream
        step_duration = max(getattr(args, "step_duration_min", 20), args.tier1_duration // (args.max - args.min + 1))
        total_duration_approx = (args.max - args.min + 1) * step_duration
        # Warn if duration is too short to actually reach max (ramp time ≈ (max - min) * step_duration)
        ramp_time_to_reach_max = (args.max - args.min) * step_duration
        if args.tier1_duration < ramp_time_to_reach_max:
            estimated_peak = min(args.max, args.min + int(args.tier1_duration / step_duration))
            print(
                f"\n*** WARNING: tier1-duration ({args.tier1_duration}s) is shorter than ramp time to --max ({ramp_time_to_reach_max}s). "
                f"You will not reach {args.max} participants; estimated peak ≈ {estimated_peak}. "
                f"Increase --tier1-duration or decrease --step-duration-min. ***\n",
                file=sys.stderr,
            )
        print(f"\n--- Single-pass ramp {args.min} -> {args.max} (step={step_duration}s, ~{total_duration_approx}s total) ---", file=sys.stderr)
        metrics_path = results_dir / "metrics_ramp.jsonl"
        if metrics_path.exists():
            metrics_path.unlink()

        sampler_proc = None
        if os.environ.get("KUBECONFIG"):
            sampler_proc = subprocess.Popen(
                [
                    sys.executable,
                    str(script_dir / "metrics_sampler_k8s.py"),
                    "--namespace", args.namespace,
                    "--interval", "2",
                    "--output", str(metrics_path),
                ],
                cwd=load_test_dir,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
            time.sleep(2)

        tier1_rc, _ = run_tier1_ramp_up(
            script_dir, load_test_dir, str(config_path),
            args.min, args.max, step_duration, config,
            start_stagger=getattr(args, "start_stagger", 0.1),
            k8s_participants=getattr(args, "k8s_participants", False),
            k8s_namespace=args.namespace,
            k8s_image=getattr(args, "k8s_image", "load-test-participant:latest"),
            k8s_image_pull_policy=getattr(args, "k8s_image_pull_policy", None),
        )
        if sampler_proc:
            sampler_proc.send_signal(signal.SIGINT)
            sampler_proc.wait(timeout=5)

        join_success, joined, total = read_load_test_result(load_test_dir)
        agg = aggregate_metrics_jsonl(metrics_path) if metrics_path.exists() else {}

        if stop_on_oom and agg.get("oom_kills", 0) > 0:
            print("Stop: OOM kills detected", file=sys.stderr)
            with open(summary_path, "a", newline="") as cf:
                w = csv.DictWriter(cf, fieldnames=fieldnames)
                w.writerow({
                    "n": args.max, "mode": "livekit-only-ramp", "join_success_rate": join_success,
                    "peak_cpu": agg.get("peak_cpu"), "peak_rss_total": agg.get("peak_rss_total"),
                    "oom_kills": agg.get("oom_kills"), "restarts": agg.get("restarts"),
                    "avg_rtt_ms": "", "packet_loss_pct": "", "tier1_exit": tier1_rc, "notes": "stopped_oom",
                })
            return 1

        row = {
            "n": args.max, "mode": "livekit-only-ramp", "join_success_rate": join_success,
            "peak_cpu": agg.get("peak_cpu"), "peak_rss_total": agg.get("peak_rss_total"),
            "oom_kills": agg.get("oom_kills", 0), "restarts": agg.get("restarts", 0),
            "avg_rtt_ms": "", "packet_loss_pct": "", "tier1_exit": tier1_rc, "notes": "",
        }
        with open(summary_path, "a", newline="") as cf:
            w = csv.DictWriter(cf, fieldnames=fieldnames)
            w.writerow(row)

        if join_success < join_success_threshold:
            print(f"Stop: join success {join_success}% < {join_success_threshold}%", file=sys.stderr)
            return 1
        print(f"Ramp complete. Summary: {summary_path}", file=sys.stderr)
        return 0

    # Per-N mode: run separate load test for each N
    for n in range(args.min, args.max + 1):
        print(f"\n--- Ramp step N={n} ---", file=sys.stderr)
        metrics_path = results_dir / f"metrics_N{n}.jsonl"
        if metrics_path.exists():
            metrics_path.unlink()

        sampler_proc = None
        if os.environ.get("KUBECONFIG"):
            sampler_proc = subprocess.Popen(
                [
                    sys.executable,
                    str(script_dir / "metrics_sampler_k8s.py"),
                    "--namespace", args.namespace,
                    "--interval", "2",
                    "--output", str(metrics_path),
                ],
                cwd=load_test_dir,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
            time.sleep(2)

        tier1_rc, _ = run_tier1(script_dir, load_test_dir, str(config_path), n, args.tier1_duration, config, start_stagger=getattr(args, "start_stagger", 0.1))
        if sampler_proc:
            sampler_proc.send_signal(signal.SIGINT)
            sampler_proc.wait(timeout=5)
        agg = aggregate_metrics_jsonl(metrics_path) if metrics_path.exists() else {}
        if stop_on_oom and agg.get("oom_kills", 0) > 0:
            print(f"Stop: OOM kills detected (N={n})", file=sys.stderr)
            with open(summary_path, "a", newline="") as cf:
                w = csv.DictWriter(cf, fieldnames=fieldnames)
                w.writerow({
                    "n": n, "mode": "livekit-only", "join_success_rate": "", "peak_cpu": agg.get("peak_cpu"),
                    "peak_rss_total": agg.get("peak_rss_total"), "oom_kills": agg.get("oom_kills"),
                    "restarts": agg.get("restarts"), "avg_rtt_ms": "", "packet_loss_pct": "",
                    "tier1_exit": tier1_rc, "notes": "stopped_oom",
                })
            return 1

        join_success, _, _ = read_load_test_result(load_test_dir)
        if join_success == 0:
            join_success = 100.0 if tier1_rc == 0 else 0.0
        row = {
            "n": n, "mode": "livekit-only", "join_success_rate": join_success,
            "peak_cpu": agg.get("peak_cpu"), "peak_rss_total": agg.get("peak_rss_total"),
            "oom_kills": agg.get("oom_kills", 0), "restarts": agg.get("restarts", 0),
            "avg_rtt_ms": "", "packet_loss_pct": "", "tier1_exit": tier1_rc, "notes": "",
        }

        time.sleep(args.cooldown)

        if not args.skip_tier2 and args.room_url:
            webrtc_path = results_dir / f"webrtc_stats_N{n}.jsonl"
            t2_rc, avg_rtt, loss = run_tier2(script_dir, load_test_dir, args.room_url, n, args.tier2_duration, webrtc_path)
            row["mode"] = "full-ui"
            row["avg_rtt_ms"] = f"{avg_rtt:.1f}" if avg_rtt is not None else ""
            row["packet_loss_pct"] = f"{loss:.2f}" if loss is not None else ""
            if t2_rc != 0:
                row["notes"] = (row["notes"] + " tier2_fail").strip()
        elif not args.skip_tier2 and not args.room_url:
            row["notes"] = "tier2_skipped_no_room_url"

        with open(summary_path, "a", newline="") as cf:
            w = csv.DictWriter(cf, fieldnames=fieldnames)
            w.writerow(row)

        if join_success < join_success_threshold:
            print(f"Stop: join success {join_success}% < {join_success_threshold}%", file=sys.stderr)
            return 1

    print(f"Ramp complete. Summary: {summary_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
