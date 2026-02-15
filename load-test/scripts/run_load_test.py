#!/usr/bin/env python3
"""
Orchestrator: load config, optionally create users/room, spawn N participant processes,
run safety loop (poll load / errors), run for duration or until safety triggered, then tear down.
Exit 0 = success, 2 = safety triggered.

Note: The 1c/1g resource limit applies only to the k8s test environment (Matrix stack).
The host running this script can use full CPU/memory and parallelism; start participants
with minimal stagger (--start-stagger) to load the stack as the host allows.
"""
import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import requests
import yaml


def load_config(config_path: str) -> dict:
    with open(config_path) as f:
        return yaml.safe_load(f)


def get_load1_prometheus(prometheus_url: str) -> float | None:
    """Query Prometheus for node_load1. Returns value or None on error."""
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


def get_load1_proc() -> float | None:
    """Read load1 from /proc/loadavg (works when running on the target host)."""
    try:
        with open("/proc/loadavg") as f:
            return float(f.read().split()[0])
    except Exception:
        return None


def get_load1_ssh(remote: str) -> float | None:
    """Read load1 from /proc/loadavg on remote host via ssh (for local orchestrator)."""
    try:
        out = subprocess.run(
            ["ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", remote, "cat /proc/loadavg"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if out.returncode == 0 and out.stdout:
            return float(out.stdout.split()[0])
    except Exception:
        pass
    return None


def get_load1(prometheus_url: str, safety_load_ssh: str | None = None) -> tuple[float | None, str]:
    """Return (load1, source). Tries Prometheus, then SSH /proc/loadavg, then local /proc/loadavg."""
    load1 = get_load1_prometheus(prometheus_url)
    if load1 is not None:
        return load1, "prometheus"
    if safety_load_ssh:
        load1 = get_load1_ssh(safety_load_ssh)
        if load1 is not None:
            return load1, "ssh"
    load1 = get_load1_proc()
    if load1 is not None:
        return load1, "proc"
    return None, "none"


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Matrix+LiveKit load test with safety kill switch")
    parser.add_argument("--config", default="config.yaml", help="Config file path")
    parser.add_argument("--participants", type=int, help="Number of participants (overrides config)")
    parser.add_argument("--duration", type=int, help="Duration in seconds (overrides config)")
    parser.add_argument("--create-users", action="store_true", help="Run create_test_users.py first")
    parser.add_argument("--collect-metrics", action="store_true", help="Run collect_metrics.py in background")
    parser.add_argument("--metrics-interval", type=int, default=10, help="Metrics collection interval (seconds)")
    parser.add_argument("--no-create-users", action="store_true", help="Skip user/room creation (use existing)")
    parser.add_argument("--ramp-up", action="store_true", help="Ramp up: start min, add one every step_duration until max (single run)")
    parser.add_argument("--min-participants", type=int, help="With --ramp-up: starting participant count")
    parser.add_argument("--max-participants", type=int, help="With --ramp-up: ceiling participant count")
    parser.add_argument("--step-duration", type=int, default=60, help="With --ramp-up: seconds between adding one participant")
    parser.add_argument("--start-stagger", type=float, default=0.1, help="Seconds between starting each participant (0 = start all in parallel; host can use full parallelism)")
    args = parser.parse_args()

    if not os.path.isfile(args.config):
        print(f"Error: {args.config} not found. Copy from config.example.yaml.", file=sys.stderr)
        return 1

    config = load_config(args.config)
    ramp_up = getattr(args, "ramp_up", False)
    if ramp_up:
        min_p = args.min_participants or 2
        max_p = args.max_participants or 10
        step_dur = args.step_duration or 60
        n = max_p
        duration = (max_p - min_p + 1) * step_dur
    else:
        n = args.participants or config.get("participants", 5)
        duration = args.duration or config.get("duration_seconds", 120)
        min_p = max_p = step_dur = None
    safety_cfg = config.get("safety") or {}
    load1_max = safety_cfg.get("load1_max", 2.0)
    consecutive_errors_max = safety_cfg.get("consecutive_errors_max", 5)
    prometheus_url = (os.environ.get("PROMETHEUS_URL") or safety_cfg.get("prometheus_url") or "").strip()
    safety_load_ssh = (os.environ.get("SAFETY_LOAD_SSH") or safety_cfg.get("safety_load_ssh") or "").strip() or None
    users_file = config.get("test_users_file", "test_users.json")
    script_dir = Path(__file__).resolve().parent
    load_test_dir = script_dir.parent
    os.chdir(load_test_dir)

    # Create users and room (unless --no-create-users or users file already present)
    we_created_users = False
    if args.create_users or (not args.no_create_users and not os.path.isfile(load_test_dir / users_file)):
        we_created_users = True
        # So we get a fresh room for the new users, remove stale room id and don't pass TEST_ROOM_ID
        room_id_file = load_test_dir / "test_room_id.txt"
        if room_id_file.exists():
            room_id_file.unlink()
        env_create = {k: v for k, v in os.environ.items() if k != "TEST_ROOM_ID"}
        rc = subprocess.call(
            [sys.executable, str(script_dir / "create_test_users.py"), "--config", args.config, "--participants", str(n), "--force"],
            cwd=load_test_dir,
            env=env_create,
        )
        if rc != 0:
            print("create_test_users.py failed", file=sys.stderr)
            return rc

    if not os.path.isfile(load_test_dir / users_file):
        print(f"Error: {users_file} not found. Run with --create-users first.", file=sys.stderr)
        return 1

    with open(users_file) as f:
        users = json.load(f).get("users", [])
    if len(users) < n:
        print(f"Error: need at least {n} users in {users_file}", file=sys.stderr)
        return 1

    room_id = os.environ.get("TEST_ROOM_ID") or config.get("test_room_id")
    if not room_id and os.path.isfile(load_test_dir / "test_room_id.txt"):
        with open(load_test_dir / "test_room_id.txt") as f:
            room_id = f.read().strip()
    if not room_id:
        print("Error: test_room_id not set and test_room_id.txt not found", file=sys.stderr)
        return 1

    safety_file = load_test_dir / ".safety_triggered"
    if safety_file.exists():
        safety_file.unlink()
    env = os.environ.copy()
    env["TEST_ROOM_ID"] = room_id

    procs: list[tuple[int, subprocess.Popen]] = []

    safety_triggered = False
    if ramp_up:
        # Ramp-up: start min_p at t=0, then add one every step_dur until max_p. Single continuous run.
        total_duration = duration  # (max_p - min_p + 1) * step_dur
        start_time = time.monotonic()
        print(f"[ramp-up] min={min_p} max={max_p} step={step_dur}s total={total_duration}s", file=sys.stderr)

        # Start initial batch 0..min_p-1
        stagger = max(0, getattr(args, "start_stagger", 0.1))
        for i in range(min_p):
            cmd = [
                sys.executable,
                str(script_dir / "participant.py"),
                "--config", args.config,
                "--user-index", str(i),
                "--duration", str(total_duration),
                "--safety-file", str(safety_file),
            ]
            p = subprocess.Popen(cmd, cwd=load_test_dir, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            procs.append((i, p))
            if stagger > 0:
                time.sleep(stagger)
        print(f"[ramp-up] started {min_p} participants", file=sys.stderr)
        next_to_start = min_p

        # Loop: every 2s check safety; every step_dur add one participant until max_p
        while time.monotonic() - start_time < total_duration + 5:
            elapsed = time.monotonic() - start_time
            if safety_file.exists():
                safety_triggered = True
                break
            # Add next participant when due (at step_dur, 2*step_dur, ...)
            if next_to_start < max_p:
                due = (next_to_start - min_p + 1) * step_dur
                if elapsed >= due:
                    part_duration = total_duration - due
                    cmd = [
                        sys.executable,
                        str(script_dir / "participant.py"),
                        "--config", args.config,
                        "--user-index", str(next_to_start),
                        "--duration", str(max(10, int(part_duration))),
                        "--safety-file", str(safety_file),
                    ]
                    p = subprocess.Popen(cmd, cwd=load_test_dir, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                    procs.append((next_to_start, p))
                    print(f"[ramp-up] +1 participant {next_to_start} (n={next_to_start + 1} total)", file=sys.stderr)
                    next_to_start += 1

            load1, source = get_load1(prometheus_url, safety_load_ssh)
            if load1 is not None and int(elapsed) % 10 < 2:
                print(f"[safety] load1={load1:.2f} (source={source}, max={load1_max})", file=sys.stderr)
            if load1 is not None and load1 > load1_max:
                safety_triggered = True
                safety_file.write_text("1")
                break
            errors = sum(1 for _, p in procs if p.poll() is not None and p.returncode != 0)
            if errors >= consecutive_errors_max:
                safety_triggered = True
                safety_file.write_text("1")
                break
            time.sleep(2)

        safety_file.write_text("1")
    else:
        # Original: start all N participants (stagger optional; 0 = full parallel on host)
        stagger = max(0, getattr(args, "start_stagger", 0.1))
        for i in range(n):
            cmd = [
                sys.executable,
                str(script_dir / "participant.py"),
                "--config", args.config,
                "--user-index", str(i),
                "--duration", str(duration),
                "--safety-file", str(safety_file),
            ]
            p = subprocess.Popen(cmd, cwd=load_test_dir, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            procs.append((i, p))
            if stagger > 0:
                time.sleep(stagger)

        # Optional metrics collector
        metrics_proc = None
        if args.collect_metrics and prometheus_url:
            metrics_proc = subprocess.Popen(
                [sys.executable, str(script_dir / "collect_metrics.py"), "--config", args.config, "--interval", str(args.metrics_interval)],
                cwd=load_test_dir,
                env=env,
            )

        # Safety loop
        safety_triggered = False
        start = time.monotonic()
        loop_count = 0
        while time.monotonic() - start < duration + 5:
            if safety_file.exists():
                safety_triggered = True
                print("SAFETY TRIGGERED (file present)", file=sys.stderr)
                break
            load1, source = get_load1(prometheus_url, safety_load_ssh)
            if load1 is not None:
                if loop_count % 5 == 0:
                    print(f"[safety] load1={load1:.2f} (source={source}, max={load1_max})", file=sys.stderr)
                if load1 > load1_max:
                    safety_triggered = True
                    print(f"SAFETY TRIGGERED: load1={load1} > {load1_max} (source={source})", file=sys.stderr)
                    safety_file.write_text("1")
                    break
            errors = sum(1 for _, p in procs if p.poll() is not None and p.returncode != 0)
            if errors >= consecutive_errors_max:
                safety_triggered = True
                print(f"SAFETY TRIGGERED: {errors} participant errors >= {consecutive_errors_max}", file=sys.stderr)
                safety_file.write_text("1")
                break
            loop_count += 1
            time.sleep(2)

        safety_file.write_text("1")
        if metrics_proc:
            metrics_proc.terminate()
            metrics_proc.wait(timeout=5)

    # Wait for all participants
    timeout_remaining = 30
    joined_ok = 0
    for i, p in procs:
        try:
            p.wait(timeout=timeout_remaining)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait(timeout=5)
        if p.returncode == 0:
            joined_ok += 1
        else:
            err = (p.stderr and p.stderr.read()) or b""
            print(f"Participant {i} stderr: {err.decode(errors='replace')}", file=sys.stderr)

    # Write result for harness (join success, etc.)
    result_path = load_test_dir / ".load_test_result.json"
    total_started = len(procs)
    with open(result_path, "w") as f:
        json.dump({"joined": joined_ok, "total": total_started, "success_rate_pct": (100.0 * joined_ok / total_started) if total_started else 0}, f)

    # Remove (deactivate) test users if we created them this run
    if we_created_users:
        subprocess.call(
            [sys.executable, str(script_dir / "remove_test_users.py"), "--config", args.config, "--users-file", users_file],
            cwd=load_test_dir,
        )

    # Exit: 2 = safety triggered, 1 = one or more participants failed, 0 = all ok
    if safety_triggered:
        return 2
    if joined_ok < total_started:
        print(f"[result] {joined_ok}/{total_started} participants succeeded", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
