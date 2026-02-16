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
import collections
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import requests
import yaml


def load_config(config_path: str) -> dict:
    with open(config_path) as f:
        return yaml.safe_load(f)


def get_load1_prometheus(prometheus_url: str, query: str | None = None) -> float | None:
    """Query Prometheus for load (default node_load1). Use safety.prometheus_load1_query or PROMETHEUS_LOAD1_QUERY to target a specific node."""
    if not prometheus_url:
        return None
    q = (query or "").strip() or "node_load1"
    try:
        r = requests.get(
            f"{prometheus_url.rstrip('/')}/api/v1/query",
            params={"query": q},
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


def verify_ssh_load_source(remote: str) -> tuple[str | None, str | None, str | None]:
    """Run one SSH to remote, return (hostname, full_loadavg_line, stderr_or_none). So you can confirm which host we're reading load from."""
    try:
        out = subprocess.run(
            [
                "ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", remote,
                "hostname 2>/dev/null; cat /proc/loadavg",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if out.returncode != 0:
            return None, None, (out.stderr or "").strip() or None
        lines = (out.stdout or "").strip().split("\n")
        hostname = lines[0].strip() if lines else None
        loadavg_line = lines[1].strip() if len(lines) > 1 else None
        return hostname, loadavg_line, None
    except Exception as e:
        return None, None, str(e)


def _parse_proc_net_dev(content: str) -> tuple[int | None, int | None]:
    """Parse /proc/net/dev: return (total_rx_bytes, total_tx_bytes). Skip header lines."""
    rx_total = tx_total = 0
    for line in content.strip().split("\n"):
        if ":" not in line or line.strip().startswith("Inter-") or line.strip().startswith("face"):
            continue
        parts = line.replace(":", " ").split()
        if len(parts) >= 10:
            try:
                rx_total += int(parts[1])
                tx_total += int(parts[9])
            except (ValueError, IndexError):
                pass
    return (rx_total, tx_total) if (rx_total or tx_total) else (None, None)


def get_net_io_proc() -> tuple[int | None, int | None]:
    """Read /proc/net/dev on local host. Returns (rx_bytes, tx_bytes) cumulative."""
    try:
        with open("/proc/net/dev") as f:
            rx, tx = _parse_proc_net_dev(f.read())
            return rx, tx
    except Exception:
        return None, None


def get_net_io_ssh(remote: str) -> tuple[int | None, int | None]:
    """Read /proc/net/dev on remote host via SSH. Returns (rx_bytes, tx_bytes) cumulative."""
    try:
        out = subprocess.run(
            ["ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", remote, "cat /proc/net/dev"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if out.returncode == 0 and out.stdout:
            return _parse_proc_net_dev(out.stdout)
    except Exception:
        pass
    return None, None


def get_node_stats_ssh(remote: str) -> tuple[float | None, int | None, int | None, int | None]:
    """One SSH: load1, MemAvailable (MB), net_rx_bytes, net_tx_bytes from node."""
    try:
        out = subprocess.run(
            [
                "ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", remote,
                "cat /proc/loadavg; grep MemAvailable /proc/meminfo 2>/dev/null; cat /proc/net/dev",
            ],
            capture_output=True,
            text=True,
            timeout=12,
        )
        if not out.stdout:
            load1, mem = get_load1_ssh(remote), None
            net_rx, net_tx = get_net_io_ssh(remote) if load1 is not None else (None, None)
            return load1, mem, net_rx, net_tx
        lines = out.stdout.strip().split("\n")
        load1 = float(lines[0].split()[0]) if lines else None
        mem_mb = None
        net_start = None  # first line of /proc/net/dev (header "Inter-" or " face")
        for i, line in enumerate(lines[1:], 1):
            if "MemAvailable" in line:
                parts = line.split()
                if len(parts) >= 2:
                    mem_mb = int(int(parts[1]) / 1024)
            if "Receive" in line and "Transmit" in line:
                net_start = i
                break
        net_rx, net_tx = _parse_proc_net_dev("\n".join(lines[net_start:])) if net_start is not None else (None, None)
        return load1, mem_mb, net_rx, net_tx
    except Exception:
        load1, mem = get_load1_ssh(remote), None
        net_rx, net_tx = get_net_io_ssh(remote) if load1 is not None else (None, None)
        return load1, mem, net_rx, net_tx


def get_server_latency(server_url: str) -> tuple[int | None, float | None]:
    """GET server/_matrix/client/versions. Returns (status_code, latency_sec)."""
    if not (server_url or "").strip():
        return None, None
    url = f"{server_url.rstrip('/')}/_matrix/client/versions"
    try:
        start = time.perf_counter()
        r = requests.get(url, timeout=5)
        return r.status_code, round((time.perf_counter() - start) * 1000) / 1000.0
    except Exception:
        return None, None


def get_load1(prometheus_url: str, safety_load_ssh: str | None = None, load1_query: str | None = None) -> tuple[float | None, str]:
    """Return (load1, source). Tries Prometheus, then SSH, then local /proc/loadavg.
    For --k8s-participants you must set safety_load_ssh to the k8s node (e.g. user@node-ip) so load is read from the node, not the orchestrator.
    Use load1_query (or safety.prometheus_load1_query / PROMETHEUS_LOAD1_QUERY) to target a specific node, e.g. node_load1{instance=\"node:9100\"}."""
    load1 = get_load1_prometheus(prometheus_url, query=load1_query)
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


def _k8s_in_cluster_config(config: dict, namespace: str) -> dict:
    """Build config for in-cluster use: replace localhost URLs with in-cluster service URLs."""
    import copy
    c = copy.deepcopy(config)
    ns = namespace or "matrix-qa"
    c["server_url"] = f"http://nginx.{ns}.svc"
    c["livekit_ws_url"] = f"ws://livekit.{ns}.svc:7880"
    c["livekit_jwt_url"] = f"http://lk-jwt.{ns}.svc:6080"
    c["test_users_file"] = "/secrets/test_users.json"
    return c


def _k8s_ensure_resources(
    namespace: str,
    config_yaml: str,
    test_users_path: Path,
    room_id: str,
) -> None:
    """Create or replace ConfigMap load-test-config, Secret load-test-users, ConfigMap load-test-room."""
    ns = namespace or "matrix-qa"

    with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
        f.write(config_yaml)
        config_path = f.name
    try:
        out = subprocess.run(
            ["kubectl", "create", "configmap", "load-test-config", f"--from-file=config.yaml={config_path}", "-n", ns, "--dry-run=client", "-o", "yaml"],
            capture_output=True,
            check=True,
        )
        subprocess.run(["kubectl", "apply", "-f", "-", "-n", ns], input=out.stdout, check=True)
    finally:
        os.unlink(config_path)

    out = subprocess.run(
        ["kubectl", "create", "secret", "generic", "load-test-users", f"--from-file=test_users.json={test_users_path}", "-n", ns, "--dry-run=client", "-o", "yaml"],
        capture_output=True,
        check=True,
    )
    subprocess.run(["kubectl", "apply", "-f", "-", "-n", ns], input=out.stdout, check=True)

    out = subprocess.run(
        ["kubectl", "create", "configmap", "load-test-room", f"--from-literal=test_room_id={room_id}", "-n", ns, "--dry-run=client", "-o", "yaml"],
        capture_output=True,
        check=True,
    )
    subprocess.run(["kubectl", "apply", "-f", "-", "-n", ns], input=out.stdout, check=True)


def _k8s_job_yaml(job_name: str, user_index: int, duration_sec: int, image: str, namespace: str, image_pull_policy: str | None = None, node_name: str | None = None) -> str:
    """Generate Job YAML for one participant. image_pull_policy e.g. Never when image is pre-loaded on node. node_name pins pod to that node (where we preloaded)."""
    pull_policy_line = f"\n          imagePullPolicy: {image_pull_policy}" if image_pull_policy else ""
    node_name_line = f"\n      nodeName: {node_name}" if node_name else ""
    return f"""apiVersion: batch/v1
kind: Job
metadata:
  name: {job_name}
  namespace: {namespace}
spec:
  backoffLimit: 4
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never{node_name_line}
      containers:
        - name: participant
          image: {image}{pull_policy_line}
          workingDir: /app
          command:
            - python3
            - /app/scripts/participant.py
            - --config
            - /config/config.yaml
            - --user-index
            - "{user_index}"
            - --duration
            - "{duration_sec}"
          env:
            - name: TEST_ROOM_ID
              valueFrom:
                configMapKeyRef:
                  name: load-test-room
                  key: test_room_id
          volumeMounts:
            - name: config
              mountPath: /config
              readOnly: true
            - name: users
              mountPath: /secrets
              readOnly: true
          resources:
            requests:
              memory: "1Gi"
              cpu: "500m"
            limits:
              memory: "4Gi"
              cpu: "2000m"
      volumes:
        - name: config
          configMap:
            name: load-test-config
        - name: users
          secret:
            secretName: load-test-users
"""


def _k8s_apply_job(yaml_str: str) -> None:
    subprocess.run(["kubectl", "apply", "-f", "-"], input=yaml_str.encode(), check=True)


def _k8s_delete_jobs(namespace: str, job_name_prefix: str) -> None:
    """Delete all Jobs with the given name prefix so we can recreate them (Job spec is immutable)."""
    statuses = _k8s_job_statuses(namespace, job_name_prefix)
    if not statuses:
        return
    names = [name for name, _ in statuses]
    subprocess.run(
        ["kubectl", "delete", "job", "-n", namespace, "--ignore-not-found=true", "--wait=false"] + names,
        capture_output=True,
        timeout=30,
    )
    # Brief wait for API to clear so apply can create fresh Jobs
    time.sleep(2)


def _k8s_wait_no_loadtest_pods(namespace: str, job_name_prefix: str, timeout_sec: float = 30.0) -> bool:
    """Wait until no running or pending pods match the prefix (so ramp pod counts reflect this run only)."""
    deadline = time.monotonic() + timeout_sec
    while time.monotonic() < deadline:
        running, pending, _, _ = _k8s_pod_counts(namespace, job_name_prefix)
        if running == 0 and pending == 0:
            return True
        time.sleep(1)
    return False


def _k8s_job_statuses(namespace: str, job_name_prefix: str) -> list[tuple[str, int | None]]:
    """Return list of (job_name, exit_code or None if not finished)."""
    out = subprocess.run(
        ["kubectl", "get", "jobs", "-n", namespace, "-o", "json"],
        capture_output=True,
        text=True,
        timeout=15,
    )
    if out.returncode != 0:
        return []
    data = json.loads(out.stdout)
    result = []
    for item in data.get("items", []):
        name = item.get("metadata", {}).get("name", "")
        if not name.startswith(job_name_prefix):
            continue
        succeeded = item.get("status", {}).get("succeeded", 0)
        failed = item.get("status", {}).get("failed", 0)
        if succeeded:
            result.append((name, 0))
        elif failed:
            result.append((name, 1))
        else:
            result.append((name, None))
    return result


def _k8s_job_status_counts(namespace: str, job_name_prefix: str) -> tuple[int, int, int]:
    """Return (active, succeeded, failed) from Job status. Source of truth; pods can be GC'd (ttlSecondsAfterFinished)."""
    out = subprocess.run(
        ["kubectl", "get", "jobs", "-n", namespace, "-o", "json"],
        capture_output=True,
        text=True,
        timeout=15,
    )
    if out.returncode != 0:
        return 0, 0, 0
    data = json.loads(out.stdout)
    active = succeeded = failed = 0
    for item in data.get("items", []):
        name = item.get("metadata", {}).get("name", "")
        if not name.startswith(job_name_prefix):
            continue
        st = item.get("status", {})
        active += st.get("active", 0)
        succeeded += st.get("succeeded", 0)
        failed += st.get("failed", 0)
    return active, succeeded, failed


def _k8s_oom_pods(namespace: str, pod_prefix: str | None = None) -> list[str]:
    """Return list of pod names that have OOMKilled in container lastState. Use pod_prefix to filter (e.g. 'loadtest-p-')."""
    out = subprocess.run(
        ["kubectl", "get", "pods", "-n", namespace, "-o", "json"],
        capture_output=True,
        text=True,
        timeout=15,
    )
    if out.returncode != 0:
        return []
    try:
        data = json.loads(out.stdout)
    except json.JSONDecodeError:
        return []
    oom_pods = []
    for item in data.get("items", []):
        name = item.get("metadata", {}).get("name", "")
        if pod_prefix and not name.startswith(pod_prefix):
            continue
        for cs in item.get("status", {}).get("containerStatuses") or []:
            if cs.get("lastState", {}).get("terminated", {}).get("reason") == "OOMKilled":
                oom_pods.append(name)
                break
    return oom_pods


def _k8s_oom_in_namespace(namespace: str, pod_prefix: str | None = None) -> bool:
    """Return True if any pod (optionally with name starting with pod_prefix) has OOMKilled."""
    return len(_k8s_oom_pods(namespace, pod_prefix)) > 0


def _k8s_pod_counts(namespace: str, job_name_prefix: str) -> tuple[int, int, int, int]:
    """Return (running, pending, failed, succeeded) pod counts for pods matching job prefix.
    Prefer _k8s_job_status_counts for ramp display; pods may be GC'd after Job completes."""
    out = subprocess.run(
        ["kubectl", "get", "pods", "-n", namespace, "-o", "json"],
        capture_output=True,
        text=True,
        timeout=15,
    )
    if out.returncode != 0:
        return 0, 0, 0, 0
    data = json.loads(out.stdout)
    running = pending = failed = succeeded = 0
    for item in data.get("items", []):
        name = item.get("metadata", {}).get("name", "")
        if not name.startswith(job_name_prefix):
            continue
        phase = item.get("status", {}).get("phase", "")
        if phase == "Running":
            running += 1
        elif phase == "Pending":
            pending += 1
        elif phase == "Succeeded":
            succeeded += 1
        else:
            failed += 1
    return running, pending, failed, succeeded


def _k8s_first_running_pod(namespace: str, job_name_prefix: str) -> str | None:
    """Return name of first Running pod for our job prefix, else None."""
    out = subprocess.run(
        ["kubectl", "get", "pods", "-n", namespace, "-o", "json", "--field-selector=status.phase=Running"],
        capture_output=True,
        text=True,
        timeout=10,
    )
    if out.returncode != 0:
        return None
    for item in json.loads(out.stdout).get("items", []):
        name = item.get("metadata", {}).get("name", "")
        if name.startswith(job_name_prefix):
            return name
    return None


def _k8s_list_running_loadtest_pods(namespace: str, job_name_prefix: str) -> list[tuple[str, int]]:
    """Return list of (pod_name, job_index) for Running pods matching job prefix, sorted by job index."""
    out = subprocess.run(
        ["kubectl", "get", "pods", "-n", namespace, "-o", "json", "--field-selector=status.phase=Running"],
        capture_output=True,
        text=True,
        timeout=10,
    )
    if out.returncode != 0:
        return []
    # Pod name is like loadtest-p-0-abc12 -> job index 0
    match_idx = re.compile(r"^" + re.escape(job_name_prefix) + r"(\d+)-").match
    result = []
    for item in json.loads(out.stdout).get("items", []):
        name = item.get("metadata", {}).get("name", "")
        if not name.startswith(job_name_prefix):
            continue
        m = match_idx(name)
        if m:
            result.append((name, int(m.group(1))))
    result.sort(key=lambda x: x[1])
    return result


# Pod name prefixes for stack (server) vs loadtest (clients). Used to split kubectl top.
_STACK_POD_PREFIXES = ("nginx-", "synapse-", "lk-jwt-", "livekit-", "postgres-")
_LOADTEST_POD_PREFIX = "loadtest-p-"


def _k8s_pod_top_split(namespace: str) -> tuple[int, int, int, int, int, int]:
    """kubectl top pods; split into stack (server) vs loadtest (clients). Returns (stack_cpu_m, stack_mem_mi, stack_n, loadtest_cpu_m, loadtest_mem_mi, loadtest_n)."""
    try:
        out = subprocess.run(
            ["kubectl", "top", "pods", "-n", namespace, "--no-headers"],
            capture_output=True,
            text=True,
            timeout=12,
        )
        if out.returncode != 0 or not out.stdout:
            return 0, 0, 0, 0, 0, 0
    except Exception:
        return 0, 0, 0, 0, 0, 0
    stack_cpu = stack_mem = stack_n = 0
    loadtest_cpu = loadtest_mem = loadtest_n = 0
    for line in out.stdout.strip().split("\n"):
        if not line or len(line.split()) < 3:
            continue
        parts = line.split()
        name = parts[0]
        if name.startswith(_LOADTEST_POD_PREFIX):
            bucket_cpu, bucket_mem, bucket_n = loadtest_cpu, loadtest_mem, loadtest_n
            is_loadtest = True
        elif any(name.startswith(p) for p in _STACK_POD_PREFIXES):
            bucket_cpu, bucket_mem, bucket_n = stack_cpu, stack_mem, stack_n
            is_loadtest = False
        else:
            continue
        try:
            cpu_s = parts[1].replace("m", "").replace("%", "")
            if "m" in parts[1]:
                c = int(float(cpu_s) if cpu_s else 0)
            elif "%" in parts[1]:
                c = int(float(cpu_s) * 10)
            else:
                c = int(float(cpu_s) * 1000)
            mem_s = parts[2].replace("Mi", "").replace("MiB", "").replace("Gi", "").replace("GiB", "")
            if "Gi" in parts[2] or "G" in parts[2]:
                m = int(float(mem_s) * 1024) if mem_s else 0
            else:
                m = int(float(mem_s)) if mem_s else 0
            bucket_cpu += c
            bucket_mem += m
            bucket_n += 1
            if is_loadtest:
                loadtest_cpu, loadtest_mem, loadtest_n = bucket_cpu, bucket_mem, bucket_n
            else:
                stack_cpu, stack_mem, stack_n = bucket_cpu, bucket_mem, bucket_n
        except (ValueError, IndexError):
            pass
    return stack_cpu, stack_mem, stack_n, loadtest_cpu, loadtest_mem, loadtest_n


def _k8s_pod_log_tail(namespace: str, pod_name: str, tail: int = 2) -> str:
    """Return last tail lines of pod log (single line, no newlines). Combines stdout+stderr (participant prints proof to stderr)."""
    try:
        out = subprocess.run(
            ["kubectl", "logs", "-n", namespace, pod_name, f"--tail={tail}", "--all-containers=true"],
            capture_output=True,
            text=True,
            timeout=8,
        )
        if out.returncode == 0:
            out_log = (out.stdout or "").strip()
            err_log = (out.stderr or "").strip()
            combined = out_log + (" " + err_log if err_log else "") or ""
            if combined:
                return " ".join(combined.split())
    except Exception:
        pass
    return ""


def _extract_proof_from_log(log_text: str) -> str:
    """Extract the most recent proof (sent + received video/audio) from participant log. Uses last match so p-0 shows higher counts."""
    if not log_text or "proof:" not in log_text:
        return ""
    # New format: "proof: sent N video, M audio | received Rv video, Ra audio" or "proof: total sent ... | received ..."
    # Find ALL proof lines, use LAST. Capture sent (v,a) and received (rv,ra).
    all_m = re.findall(
        r"proof:\s+(?:sent|total\s+sent)\s+(\d+)\s+video\s*,\s*(\d+)\s+audio\s*\|\s*received\s+(\d+)\s+video\s*,\s*(\d+)\s+audio",
        log_text,
        re.I,
    )
    if all_m:
        v, a, rv, ra = all_m[-1]
        return f"{v}v {a}a rx:{rv}v {ra}a"
    # Fallback: sent-only format (legacy)
    all_m = re.findall(
        r"proof:\s+(?:sent|total)\s+(\d+)\s+video\s+frames?,?\s+(\d+)\s+audio", log_text, re.I
    )
    if all_m:
        v, a = all_m[-1]
        return f"{v}v {a}a"
    all_m = re.findall(r"proof:\s+\S+\s+(\d+)\s+video\s+\S+\s+(\d+)\s+audio", log_text, re.I)
    if all_m:
        v, a = all_m[-1]
        return f"{v}v {a}a"
    return ""


def _k8s_proof_per_participant(namespace: str, job_prefix: str) -> str:
    """Get proof line from each running loadtest pod; return compact string like 'p-0 692v 1461a | p-1 ...'."""
    pods = _k8s_list_running_loadtest_pods(namespace, job_prefix)
    if not pods:
        return "(no running pods)"
    parts = []
    for pod_name, idx in pods:
        log = _k8s_pod_log_tail(namespace, pod_name, tail=80)
        proof = _extract_proof_from_log(log)
        if proof:
            parts.append(f"p-{idx} {proof}")
        else:
            parts.append(f"p-{idx} (no proof yet)")
    return " | ".join(parts)


def _write_ramp_metrics_summary(load_samples_path: Path, results_dir: Path) -> None:
    """Read load_ramp.jsonl; write results/ramp_metrics_summary.json with min/median/max load, latency, I/O (node vs local)."""
    samples = []
    try:
        if load_samples_path.exists():
            with open(load_samples_path) as f:
                for line in f:
                    line = line.strip()
                    if line:
                        samples.append(json.loads(line))
    except (OSError, json.JSONDecodeError):
        return
    if not samples:
        return
    def stats(key: str):
        vals = [s[key] for s in samples if s.get(key) is not None]
        if not vals:
            return None
        vals = sorted(vals)
        n = len(vals)
        return {"min": vals[0], "max": vals[-1], "median": vals[n // 2], "samples": n}
    t0, t1 = samples[0].get("t"), samples[-1].get("t")
    duration_s = (t1 - t0) if (t0 is not None and t1 is not None and t1 > t0) else None
    out = {
        "duration_s": round(duration_s, 1) if duration_s else None,
        "load1_node": stats("load1_node"),
        "load1_stack_node": stats("load1_stack_node"),
        "load1_local": stats("load1_local"),
        "server_latency_ms": stats("server_latency_ms"),
        "node_mem_available_mb": stats("node_mem_available_mb"),
        "stack_cpu_m": stats("stack_cpu_m"),
        "stack_mem_mi": stats("stack_mem_mi"),
        "loadtest_cpu_m": stats("loadtest_cpu_m"),
        "loadtest_mem_mi": stats("loadtest_mem_mi"),
    }
    # Per-participant load: CPU/mem from client pods only (correct). load1 = whole node so use incremental.
    max_n = max((s.get("n") or s.get("jobs_created") or 0) for s in samples)
    if max_n >= 1:
        peak_samples = [s for s in samples if (s.get("n") or s.get("jobs_created") or 0) >= max(1, max_n - 1)]
        cpu_per, mem_per = [], []
        for s in peak_samples:
            n = s.get("n") or s.get("jobs_created") or 1
            if n < 1:
                continue
            if s.get("loadtest_cpu_m") is not None:
                cpu_per.append(s["loadtest_cpu_m"] / n)
            if s.get("loadtest_mem_mi") is not None:
                mem_per.append(s["loadtest_mem_mi"] / n)
        # CPU/mem: total client pod usage / n = true per-participant (kubectl top is clients only).
        # load1_node is WHOLE NODE (stack + clients). So "load per user" must be incremental:
        # (avg load at peak n - avg load at baseline n) / (peak_n - baseline_n).
        load1_added_per_user = None
        baseline_load1 = None
        baseline_n = 1
        baseline_samples = [s for s in samples if (s.get("n") or s.get("jobs_created") or 0) <= baseline_n]
        if max_n > baseline_n and peak_samples and baseline_samples:
            load1_at_peak = [s["load1_node"] for s in peak_samples if s.get("load1_node") is not None]
            load1_at_baseline = [s["load1_node"] for s in baseline_samples if s.get("load1_node") is not None]
            if load1_at_peak and load1_at_baseline:
                avg_peak = sum(load1_at_peak) / len(load1_at_peak)
                avg_baseline = sum(load1_at_baseline) / len(load1_at_baseline)
                load1_added_per_user = round((avg_peak - avg_baseline) / (max_n - baseline_n), 2)
                baseline_load1 = round(avg_baseline, 2)
        out["peak_n"] = max_n
        if baseline_load1 is not None:
            out["baseline_load1_node"] = baseline_load1
        out["per_participant"] = {
            "cpu_m": round(sum(cpu_per) / len(cpu_per)) if cpu_per else None,
            "mem_mi": round(sum(mem_per) / len(mem_per)) if mem_per else None,
            "load1_added_per_user": load1_added_per_user,
        }
    # Net I/O: first vs last cumulative bytes -> rate over duration
    if len(samples) >= 2 and duration_s and duration_s > 0:
        first, last = samples[0], samples[-1]
        for prefix in ("node_net", "local_net"):
            rx_f, tx_f = first.get(prefix + "_rx_bytes"), first.get(prefix + "_tx_bytes")
            rx_l, tx_l = last.get(prefix + "_rx_bytes"), last.get(prefix + "_tx_bytes")
            if rx_f is not None and rx_l is not None and tx_f is not None and tx_l is not None:
                out[prefix + "_bytes_per_s"] = {
                    "rx": round((rx_l - rx_f) / duration_s, 0),
                    "tx": round((tx_l - tx_f) / duration_s, 0),
                }
    summary_path = results_dir / "ramp_metrics_summary.json"
    try:
        with open(summary_path, "w") as f:
            json.dump(out, f, indent=2)
        print(f"[metrics] Summary: {summary_path}", file=sys.stderr)
        lat = out.get("server_latency_ms")
        if lat:
            print(f"  server_latency_ms: min={lat['min']} median={lat['median']} max={lat['max']}", file=sys.stderr)
        ln, lstack, ll = out.get("load1_node"), out.get("load1_stack_node"), out.get("load1_local")
        if ln or lstack or ll:
            parts = [f"node={ln}", f"local={ll}"]
            if lstack is not None:
                parts.insert(1, f"stack_node={lstack}")
            print(f"  load1: " + " ".join(parts), file=sys.stderr)
        per = out.get("per_participant")
        if per and out.get("peak_n"):
            pn = out["peak_n"]
            cpu = per.get("cpu_m")
            mem = per.get("mem_mi")
            load1_inc = per.get("load1_added_per_user")
            parts = []
            if cpu is not None:
                parts.append(f"~{cpu} mCPU")
            if mem is not None:
                parts.append(f"~{mem} Mi")
            if load1_inc is not None:
                parts.append(f"~{load1_inc} load1 added per user")
            if parts:
                print(f"  per participant (at peak n={pn}): " + ", ".join(parts) + ". Scale: (load1_max - baseline_load1) / load1_added_per_user.", file=sys.stderr)
        # Sanity: did client load actually increase over the ramp? (early vs late loadtest_cpu_m)
        try:
            if load_samples_path.exists():
                lines = [json.loads(l) for l in open(load_samples_path) if l.strip()]
                if len(lines) >= 10:
                    k = max(1, len(lines) // 5)
                    early = [s.get("loadtest_cpu_m") for s in lines[:k] if s.get("loadtest_cpu_m") is not None]
                    late = [s.get("loadtest_cpu_m") for s in lines[-k:] if s.get("loadtest_cpu_m") is not None]
                    early_avg = sum(early) / len(early) if early else 0
                    late_avg = sum(late) / len(late) if late else 0
                    n_early = lines[0].get("n") or 0
                    n_late = lines[-1].get("n") or 0
                    print(f"  loadtest_cpu_m: early_avg={early_avg:.0f}m (n={n_early}) late_avg={late_avg:.0f}m (n={n_late}) {'[load increased]' if late_avg > early_avg else '[flat or decreased - clients may be idle]'}", file=sys.stderr)
        except (OSError, json.JSONDecodeError, KeyError):
            pass
    except OSError:
        pass


def _write_participant_metrics_summary(load_test_dir: Path) -> None:
    """Parse .participant_metrics_*.json; write results/participant_metrics_summary.json; print one-line summary and RX warning if needed."""
    results_dir = load_test_dir / "results"
    results_dir.mkdir(parents=True, exist_ok=True)
    summary_path = results_dir / "participant_metrics_summary.json"
    files = sorted(load_test_dir.glob(".participant_metrics_*.json"))
    connected = 0
    rx_pass = 0
    remote_counts: list[int] = []
    for path in files:
        try:
            with open(path) as f:
                data = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue
        events = data.get("events") or []
        for ev in events:
            op = ev.get("op")
            if op == "livekit_connect" and ev.get("status") == 0:
                connected += 1
                break
        for ev in events:
            if ev.get("op") == "rx_validation" and ev.get("passed") is True:
                rx_pass += 1
                break
        for ev in events:
            if ev.get("op") == "lk_remote_snapshot":
                remote_counts.append(ev.get("remote_participant_count", 0))
                break
    total = len(files)
    avg_remote = round(sum(remote_counts) / len(remote_counts), 1) if remote_counts else None
    out = {
        "total_participants": total,
        "connected": connected,
        "rx_validation_pass": rx_pass,
        "avg_remote_participants": avg_remote,
    }
    try:
        with open(summary_path, "w") as f:
            json.dump(out, f, indent=2)
    except OSError:
        return
    print(
        f"[participant summary] {connected} connected, {rx_pass} passed RX validation, avg remote participants={avg_remote}",
        file=sys.stderr,
    )
    if connected > 1 and rx_pass == 0:
        print(
            "\n*** WARNING: Multiple participants connected but none received remote A/V (RX validation 0). "
            "You may be measuring 'N isolated publishers' instead of a real call mesh. "
            "Check: same room, subscriptions enabled (auto_subscribe), and SFU forwarding. ***\n",
            file=sys.stderr,
        )


def _k8s_dump_why_no_pods(namespace: str, job_prefix: str, jobs_created: int, log_file: Path | None = None) -> None:
    """Dump pod list and job describe/events so we can see why clients aren't running."""
    lines = ["\n--- WHY (pod list + job describe for first jobs) ---"]
    try:
        out = subprocess.run(
            ["kubectl", "get", "pods", "-n", namespace, "-o", "wide"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if out.returncode == 0 and out.stdout:
            for line in out.stdout.strip().split("\n"):
                if job_prefix in line or "NAME" in line:
                    lines.append(line)
        for i in range(min(3, jobs_created)):
            job_name = f"{job_prefix}{i}"
            out = subprocess.run(
                ["kubectl", "describe", "job", job_name, "-n", namespace],
                capture_output=True,
                text=True,
                timeout=15,
            )
            if out.returncode == 0 and out.stdout:
                lines.append(f"\n--- describe {job_name} ---")
                lines.append(out.stdout.strip())
    except Exception as e:
        lines.append(str(e))
    lines.append("--- end WHY ---\n")
    blob = "\n".join(lines)
    print(blob, file=sys.stderr)
    if log_file is not None:
        try:
            log_file.parent.mkdir(parents=True, exist_ok=True)
            existing = log_file.read_text(encoding="utf-8") if log_file.exists() else ""
            log_file.write_text(existing + blob + "\n", encoding="utf-8")
        except OSError:
            pass


def _k8s_interpret_stuck_pods(namespace: str, job_prefix: str) -> None:
    """Look at current pod state and print a short interpretation so we don't ignore the dump."""
    try:
        out = subprocess.run(
            ["kubectl", "get", "pods", "-n", namespace, "-o", "wide"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if out.returncode != 0 or not out.stdout:
            return
        running = 0
        creating = 0
        pending = 0
        pending_pods: list[str] = []
        for line in out.stdout.strip().split("\n"):
            if job_prefix not in line or "NAME" in line:
                continue
            parts = line.split()
            if len(parts) < 3:
                continue
            name = parts[0]
            status = parts[2]  # READY STATUS RESTARTS ...
            if "Running" in status:
                running += 1
            elif "ContainerCreating" in status:
                creating += 1
            elif "Pending" in status:
                pending += 1
                pending_pods.append(name)
        parts = []
        if running:
            parts.append(f"{running}r")
        if creating:
            parts.append(f"{creating} ContainerCreating")
        if pending:
            parts.append(f"{pending} Pending")
        if not parts:
            print("[ramp] Dump interpretation: no loadtest pods in get pods output.", file=sys.stderr)
            return
        msg = f"[ramp] Dump interpretation: {', '.join(parts)}."
        if pending and pending_pods:
            # Get reason for one Pending pod
            desc = subprocess.run(
                ["kubectl", "describe", "pod", pending_pods[0], "-n", namespace],
                capture_output=True,
                text=True,
                timeout=15,
            )
            if desc.returncode == 0 and desc.stdout:
                low = desc.stdout.lower()
                if "exceeded quota" in low or "forbidden: exceeded quota" in low:
                    msg += " Pending reason: EXCEEDED QUOTA — raise requests.cpu/limits.cpu (and/or memory) in k8s-qa/00-budget.yaml."
                elif "failedscheduling" in low or "0/nodes are available" in low:
                    if "insufficient cpu" in low or "cpu" in low:
                        msg += " Pending reason: insufficient CPU (scheduling). Raise limits.cpu / check node capacity."
                    elif "insufficient memory" in low or "memory" in low:
                        msg += " Pending reason: insufficient memory (scheduling). Raise limits.memory."
                    else:
                        msg += " Pending reason: FailedScheduling — see describe in job_logs.txt."
                elif "oomkilled" in low:
                    msg += " Pending/restart: OOMKilled — raise pod memory limit or limits.memory quota."
                else:
                    msg += " Pending — check Events in job_logs.txt (kubectl describe pod)."
        elif creating and not pending:
            msg += " (new pod(s) still starting; if this stays for >30s, re-check quota.)"
        print(msg, file=sys.stderr)
    except Exception as e:
        print(f"[ramp] Dump interpretation failed: {e}", file=sys.stderr)


def _k8s_dump_job_logs(
    namespace: str,
    job_prefix: str,
    job_indices: list[int],
    tail: int = 80,
    log_file: Path | None = None,
    quiet: bool = False,
) -> None:
    """Get kubectl logs for each job. Write to log_file. If not quiet, also print to stderr (use quiet=True mid-run to avoid flooding console)."""
    lines: list[str] = []
    lines.append("\n--- Job logs (last {} lines each) ---".format(tail))
    seen_image_pull_error = False
    seen_401_get_token = False
    for i in job_indices:
        job_name = f"{job_prefix}{i}"
        try:
            out = subprocess.run(
                ["kubectl", "logs", "-n", namespace, f"job/{job_name}", f"--tail={tail}", "--all-containers=true"],
                capture_output=True,
                text=True,
                timeout=30,
            )
            out_log = (out.stdout or "").strip()
            err_log = (out.stderr or "").strip()
            log = out_log + ("\n" + err_log if err_log else "") or "(no output)"
            if "image can't be pulled" in log or "ImagePullBackOff" in log or "ErrImagePull" in log:
                seen_image_pull_error = True
            if "ErrImageNeverPull" in log:
                seen_image_pull_error = True
            if any(s in log for s in ("401", "Unauthorized", "get_token")):
                seen_401_get_token = True
            block = "\n--- {} ---\n{}".format(job_name, log)
            lines.append(block)
            if not quiet:
                print(block, file=sys.stderr)
        except Exception as e:
            block = "\n--- {} (failed to get logs: {}) ---".format(job_name, e)
            lines.append(block)
            if not quiet:
                print(block, file=sys.stderr)
    if seen_image_pull_error:
        msg = "\n>>> Image error: If 'ErrImageNeverPull', the image isn't on the node (preload went to different daemon/node or cluster uses containerd). Push to a registry and run without preload: docker push <registry>/load-test-participant:latest then ./run-ramp-k8s.sh ... --k8s-image <registry>/load-test-participant:latest (do not use --k8s-image-pull-policy Never). If 'image can\'t be pulled', use minikube docker-env or push to a registry."
        lines.append(msg)
        if not quiet:
            print(msg, file=sys.stderr)
    if seen_401_get_token:
        msg = (
            "\n>>> Early exit + 401/get_token: lk-jwt must reach OpenID userinfo (nginx .well-known/matrix/server and "
            "/_matrix/federation/v1/openid/userinfo on 443/8448). Check: kubectl logs -n matrix-qa -l app=lk-jwt --tail=100. "
            "Ensure run-ramp-k8s.sh patched lk-jwt hostAliases to current nginx ClusterIP and rollout completed."
        )
        lines.append(msg)
        if not quiet:
            print(msg, file=sys.stderr)
    lines.append("--- end job logs ---\n")
    if not quiet:
        print("--- end job logs ---\n", file=sys.stderr)
    if log_file is not None:
        try:
            log_file.parent.mkdir(parents=True, exist_ok=True)
            log_file.write_text("\n".join(lines), encoding="utf-8")
            if not quiet:
                print("Job logs written to:", log_file, file=sys.stderr)
                sys.stderr.flush()
        except OSError:
            pass


def _k8s_wait_jobs(namespace: str, job_name_prefix: str, timeout_sec: int = 600) -> tuple[int, int]:
    """Wait for all Jobs with prefix to complete. Returns (succeeded_count, total_count)."""
    deadline = time.monotonic() + timeout_sec
    while time.monotonic() < deadline:
        statuses = _k8s_job_statuses(namespace, job_name_prefix)
        total = len(statuses)
        done = sum(1 for _, code in statuses if code is not None)
        succeeded = sum(1 for _, code in statuses if code == 0)
        if done == total and total > 0:
            return succeeded, total
        time.sleep(3)
    statuses = _k8s_job_statuses(namespace, job_name_prefix)
    succeeded = sum(1 for _, code in statuses if code == 0)
    return succeeded, len(statuses)


def _run_k8s_participants(
    args,
    config: dict,
    n: int,
    duration: int,
    min_p: int | None,
    max_p: int | None,
    step_dur: int | None,
    ramp_up: bool,
    room_id: str,
    load_test_dir: Path,
    users_file: str,
    we_created_users: bool,
    script_dir: Path,
) -> int:
    """Run participants as k8s Jobs; return exit code."""
    namespace = getattr(args, "k8s_namespace", "matrix-qa") or "matrix-qa"
    image = getattr(args, "k8s_image", "load-test-participant:latest") or "load-test-participant:latest"
    image_pull_policy = getattr(args, "k8s_image_pull_policy", None) or None
    # Load must be read from the k8s node (where pods run). Never use timeways.net / prod.
    # Optional: pin loadtest pods to a specific cluster node via safety.k8s_loadtest_node_name.
    node_name = (config.get("safety") or {}).get("k8s_loadtest_node_name") or None
    job_prefix = "loadtest-p-"

    k8s_config = _k8s_in_cluster_config(config, namespace)
    config_yaml = yaml.dump(k8s_config, default_flow_style=False, allow_unicode=True)
    _k8s_ensure_resources(namespace, config_yaml, load_test_dir / users_file, room_id)
    _k8s_delete_jobs(namespace, job_prefix)
    if not _k8s_wait_no_loadtest_pods(namespace, job_prefix, timeout_sec=30.0):
        print("[k8s] WARNING: old loadtest pods still present after 30s; pod counts may include previous run.", file=sys.stderr)
    else:
        print("[k8s] no loadtest pods remaining; starting fresh.", file=sys.stderr)

    safety_cfg = config.get("safety") or {}
    load1_max = safety_cfg.get("load1_max", 2.0)
    consecutive_errors_max = safety_cfg.get("consecutive_errors_max", 5)
    prometheus_url = (os.environ.get("PROMETHEUS_URL") or safety_cfg.get("prometheus_url") or "").strip()
    safety_load_ssh = (os.environ.get("SAFETY_LOAD_SSH") or safety_cfg.get("safety_load_ssh") or "").strip() or None
    # K8s-qa only: load must be from the k8s node. Never use timeways.net (prod).
    if safety_load_ssh and "timeways" in safety_load_ssh.lower():
        k8s_node = (safety_cfg.get("safety_load_ssh") or "kspld0").strip() or "kspld0"
        print(f"[k8s] Load must come from the k8s-qa node only. Overriding {safety_load_ssh!r} -> {k8s_node!r}.", file=sys.stderr)
        safety_load_ssh = k8s_node
    prometheus_load1_query = (os.environ.get("PROMETHEUS_LOAD1_QUERY") or safety_cfg.get("prometheus_load1_query") or "").strip() or None
    # Three loads: orchestrator_host (this machine / general system), client_node (pods), stack_node (Synapse/QA server).
    # - safety_load_ssh = node where LOADTEST PODS run → client_node.
    # - stack_load_ssh = optional node where STACK (Synapse, LiveKit) runs → stack_node. When unset, stack_on_orchestrator can set stack_node = orchestrator_host.
    stack_load_ssh = (safety_cfg.get("stack_load_ssh") or "").strip() or None
    stack_on_orchestrator = bool(safety_cfg.get("stack_on_orchestrator"))
    if stack_load_ssh and safety_load_ssh and stack_load_ssh.strip().lower() == safety_load_ssh.strip().lower():
        stack_load_ssh = None  # same as pods node, no need to measure twice
    load_source = (safety_load_ssh or "localhost (orchestrator)").strip()
    if not safety_load_ssh or safety_load_ssh.strip().lower() == "localhost":
        print("[k8s] WARNING: Set SAFETY_LOAD_SSH to the node where loadtest pods run. Currently measuring orchestrator/localhost.", file=sys.stderr)
    else:
        ssh_hostname, ssh_loadavg, ssh_err = verify_ssh_load_source(safety_load_ssh)
        local_hostname = None
        try:
            local_hostname = socket.gethostname()
        except Exception:
            pass
        if ssh_err:
            print(f"[k8s] SSH load verification failed (client node): {ssh_err}. Load readings may be wrong or missing.", file=sys.stderr)
        elif ssh_hostname is not None and ssh_loadavg is not None:
            load1_from_verify = ssh_loadavg.split()[0] if ssh_loadavg.split() else "?"
            print(
                f"[k8s] client_node (QA client pods): hostname={ssh_hostname!r} loadavg={ssh_loadavg!r} (1m={load1_from_verify}). "
                f"orchestrator_host (this machine)={local_hostname!r}.",
                file=sys.stderr,
            )
        else:
            print(f"[k8s] Could not get hostname/loadavg from client node {safety_load_ssh}. Check ssh {safety_load_ssh} 'hostname; cat /proc/loadavg'.", file=sys.stderr)
    # Detect when orchestrator and client node are the same host.
    orchestrator_same_as_pods = False
    if local_hostname and ssh_hostname:
        lo = (local_hostname or "").strip().lower().split(".")[0]
        sh = (ssh_hostname or "").strip().lower().split(".")[0]
        orchestrator_same_as_pods = lo == sh
    if orchestrator_same_as_pods:
        print(
            "[k8s] One host: we show host_load once (whole machine) and in-pod CPU/mem for stack_pods (Synapse, etc.) vs client_pods (loadtest) from kubectl top.",
            file=sys.stderr,
        )
    if stack_load_ssh:
        sh, sl, se = verify_ssh_load_source(stack_load_ssh)
        if se:
            print(f"[k8s] stack_node (Synapse/QA server): verification failed: {se}. Will still try to read each tick.", file=sys.stderr)
        elif sh and sl:
            print(f"[k8s] stack_node (Synapse/QA server): hostname={sh!r} loadavg={sl!r}.", file=sys.stderr)
    elif stack_on_orchestrator:
        print("[k8s] stack_node = orchestrator_host (Synapse/QA server runs on this machine).", file=sys.stderr)
    print(
        "[k8s ramp-up] One host: host_load + stack_pods (Synapse/etc. CPU+mem) + client_pods (loadtest CPU+mem). Multi-host: host loadavg + same pod metrics.",
        file=sys.stderr,
    )

    if ramp_up and min_p is not None and max_p is not None and step_dur is not None:
        total_duration = (max_p - min_p + 1) * step_dur
        start_time = time.monotonic()
        print(f"[k8s ramp-up] min={min_p} max={max_p} step={step_dur}s total={total_duration}s", file=sys.stderr)
        if min_p == max_p:
            print(f"[k8s ramp-up] min==max: no step adds; running {min_p} participants for {total_duration}s only.", file=sys.stderr)
        else:
            next_due = step_dur  # first add at t=step_dur
            print(f"[k8s ramp-up] next +1 at t={next_due}s, then every {step_dur}s until n={max_p}.", file=sys.stderr)
        # Start initial batch: we create min_p jobs (you asked for 5). Stagger job creation so we don't hammer API.
        # Each participant also does a startup delay (user_index * 5s) before token/connect so lk-jwt isn't hit by 5 at once.
        INITIAL_STAGGER_SEC = 3
        for i in range(min_p):
            job_name = f"{job_prefix}{i}"
            yaml_str = _k8s_job_yaml(job_name, i, total_duration, image, namespace, image_pull_policy, node_name)
            _k8s_apply_job(yaml_str)
            if i < min_p - 1:
                time.sleep(INITIAL_STAGGER_SEC)
        print(f"[k8s ramp-up] Created {min_p} jobs (min={min_p}). pods=XrYp = X running, Y pending; if X stays 1 then other jobs crashed — see results/job_logs.txt", file=sys.stderr)
        next_to_start = min_p
        load_window = collections.deque(maxlen=10)
        results_dir = load_test_dir / "results"
        results_dir.mkdir(parents=True, exist_ok=True)
        load_samples_path = results_dir / "load_ramp.jsonl"
        stack_cpu_m = stack_mem_mi = stack_pod_n = 0
        loadtest_cpu_m = loadtest_mem_mi = loadtest_pod_n = 0
        ramp_safety_triggered = False
        job_logs_dumped_for_early_exits = False
        peak_running = 0
        stuck_at_5r_dumped = False  # one-time dump when running stuck at 5 despite 6+ jobs
        first_time_6_jobs: float | None = None  # only declare stuck after 6+ jobs for this long
        STUCK_GRACE_AFTER_6_JOBS_SEC = 30  # give 6th+ pod time to leave ContainerCreating before dumping
        while time.monotonic() - start_time < total_duration + 5:
            elapsed = time.monotonic() - start_time
            if next_to_start < max_p:
                due = (next_to_start - min_p + 1) * step_dur
                if elapsed >= due:
                    try:
                        # Each participant runs until ramp end (first started runs longest; all run in parallel).
                        part_duration = max(10, int(total_duration - due))
                        job_name = f"{job_prefix}{next_to_start}"
                        print(f"[k8s ramp-up] t={elapsed:.0f}s adding participant {next_to_start} -> n={next_to_start + 1} total (runs {part_duration}s until ramp end)", file=sys.stderr)
                        sys.stderr.flush()
                        yaml_str = _k8s_job_yaml(job_name, next_to_start, part_duration, image, namespace, image_pull_policy, node_name)
                        _k8s_apply_job(yaml_str)
                        next_to_start += 1
                        if next_to_start >= max_p:
                            print(f"[k8s ramp-up] All {max_p} participants created; they run in parallel (first runs longest until t={total_duration}s).", file=sys.stderr)
                    except Exception as e:
                        print(f"[k8s ramp-up] FAILED to add participant {next_to_start}: {e}", file=sys.stderr)
                        next_to_start += 1  # skip so we don't retry every second
            node_mem_mb = None
            node_net_rx = node_net_tx = None
            load1_stack_node = None
            if safety_load_ssh:
                load1, node_mem_mb, node_net_rx, node_net_tx = get_node_stats_ssh(safety_load_ssh)
                source = "ssh" if load1 is not None else "none"
            else:
                load1, source = get_load1(prometheus_url, safety_load_ssh, load1_query=prometheus_load1_query)
            local_load1 = get_load1_proc()  # orchestrator host (general system)
            if stack_load_ssh:
                load1_stack_node = get_load1_ssh(stack_load_ssh)
            elif stack_on_orchestrator and local_load1 is not None:
                load1_stack_node = local_load1  # Synapse runs on orchestrator host
            else:
                load1_stack_node = None
            server_status, server_latency_sec = get_server_latency((config.get("server_url") or "").strip())
            server_latency_ms = int(server_latency_sec * 1000) if server_latency_sec is not None else None
            local_net_rx, local_net_tx = get_net_io_proc()
            # Job status is source of truth (active/succeeded/failed); pod list for running vs pending
            active, job_succeeded, job_failed = _k8s_job_status_counts(namespace, job_prefix)
            running, pending, _, _ = _k8s_pod_counts(namespace, job_prefix)
            jobs_created = next_to_start
            if load1 is not None:
                load_window.append(load1)
            # Fail fast: first OOM or first job failure. Don't run the whole ramp.
            oom_pods = _k8s_oom_pods(namespace, pod_prefix=job_prefix)
            if oom_pods:
                print(f"[ramp] FAIL: OOM kill on pod(s): {oom_pods}. Exiting immediately. See results/job_logs.txt", file=sys.stderr)
                _k8s_dump_job_logs(namespace, job_prefix, list(range(jobs_created)), tail=100, log_file=load_test_dir / "results" / "job_logs.txt")
                return 1
            # First failure and zero successes → exit now (don't add more participants or wait for full ramp).
            if jobs_created >= 1 and job_failed >= 1 and job_succeeded == 0:
                print(f"[ramp] FAIL: first participant failed ({job_failed} failed, 0 succeeded). Exiting immediately. Fix 401/OOM then re-run. See results/job_logs.txt", file=sys.stderr)
                _k8s_dump_job_logs(namespace, job_prefix, list(range(jobs_created)), tail=150, log_file=load_test_dir / "results" / "job_logs.txt")
                return 1
            # Fail fast when CLIENTS never appear (0 running): 15s = no pods at all; 20s = pods didn't come up.
            NO_RUNNING_GRACE_SEC = 20
            job_logs_path = load_test_dir / "results" / "job_logs.txt"
            if jobs_created >= 1 and running == 0:
                if pending == 0 and elapsed >= 15:
                    print(f"[ramp] FAIL: no client pods at all after 15s (jobs={jobs_created} created but 0 running, 0 pending). Exiting.", file=sys.stderr)
                    _k8s_dump_why_no_pods(namespace, job_prefix, jobs_created, job_logs_path)
                    _k8s_dump_job_logs(namespace, job_prefix, list(range(min(5, jobs_created))), tail=80, log_file=job_logs_path)
                    return 1
                if elapsed >= NO_RUNNING_GRACE_SEC:
                    print(f"[ramp] FAIL: no RUNNING pod after {elapsed:.0f}s (CLIENTS stayed 0p; jobs={jobs_created} active={active} pending={pending}). Exiting.", file=sys.stderr)
                    _k8s_dump_why_no_pods(namespace, job_prefix, jobs_created, job_logs_path)
                    _k8s_dump_job_logs(namespace, job_prefix, list(range(min(5, jobs_created))), tail=80, log_file=job_logs_path)
                    return 1
            # If we've +1'd and we're still only 1 running, fail fast so you can iterate.
            # (1) Fixed time: step_dur + 30s after start (first +1 at step_dur; give 30s for it to show Running).
            # (2) After grace: we have more than min_p jobs but only 1 running and at least one job already finished → abort.
            #    Don't check (2) in the same second we added (new pod may not be counted yet); require step_dur + 15s.
            PLUS_ONE_GRACE_SEC = 30
            GRACE_AFTER_ADD_SEC = 15  # give new pod time to appear in job status before failing on active < jobs_created
            if jobs_created > min_p and running <= 1:
                if elapsed >= step_dur + PLUS_ONE_GRACE_SEC:
                    print(f"[ramp] FAIL: +1 participants not staying up (still {running}r, {jobs_created} jobs). Exiting. See results/job_logs.txt", file=sys.stderr)
                    _k8s_dump_why_no_pods(namespace, job_prefix, jobs_created, job_logs_path)
                    _k8s_dump_job_logs(namespace, job_prefix, list(range(jobs_created)), tail=150, log_file=job_logs_path)
                    return 1
                if elapsed >= step_dur + GRACE_AFTER_ADD_SEC and active < jobs_created:
                    # At least one added job already finished (failed/succeeded); no point waiting.
                    print(f"[ramp] FAIL: +1 jobs are finishing without staying up (started={jobs_created} active={active} running={running}). Exiting. See results/job_logs.txt", file=sys.stderr)
                    _k8s_dump_why_no_pods(namespace, job_prefix, jobs_created, job_logs_path)
                    _k8s_dump_job_logs(namespace, job_prefix, list(range(jobs_created)), tail=150, log_file=job_logs_path)
                    return 1
            # If some jobs finished early, warn but continue the ramp so we still get load data.
            # Only fail when no pods are left (running==0 after grace).
            completed = job_succeeded + job_failed
            if completed > 0 and active < jobs_created and jobs_created >= 1:
                early_n = jobs_created - active
                if int(elapsed) % 10 == 0 and elapsed >= 20:  # log at most every 10s to avoid spam
                    print(
                        f"[ramp] WARNING: {early_n} job(s) finished early (active={active} succeeded={job_succeeded} failed={job_failed}). Continuing ramp.",
                        file=sys.stderr,
                    )
            # Refresh pod CPU/mem every 3s so we have recent server vs client split; use cached on every tick.
            if int(elapsed) % 3 == 0:
                stack_cpu_m, stack_mem_mi, stack_pod_n, loadtest_cpu_m, loadtest_mem_mi, loadtest_pod_n = _k8s_pod_top_split(namespace)
            try:
                sample = {
                    "t": round(elapsed, 1),
                    "load1_node": load1,
                    "load1_stack_node": load1_stack_node,
                    "load1_local": local_load1,
                    "source": source,
                    "node_mem_available_mb": node_mem_mb,
                    "node_net_rx_bytes": node_net_rx,
                    "node_net_tx_bytes": node_net_tx,
                    "local_net_rx_bytes": local_net_rx,
                    "local_net_tx_bytes": local_net_tx,
                    "stack_cpu_m": stack_cpu_m,
                    "stack_mem_mi": stack_mem_mi,
                    "stack_pod_count": stack_pod_n,
                    "loadtest_cpu_m": loadtest_cpu_m,
                    "loadtest_mem_mi": loadtest_mem_mi,
                    "loadtest_pod_count": loadtest_pod_n,
                    "server_status": server_status,
                    "server_latency_ms": server_latency_ms,
                    "n": jobs_created,
                    "jobs_created": jobs_created,
                    "active": active,
                    "job_succeeded": job_succeeded,
                    "job_failed": job_failed,
                }
                with open(load_samples_path, "a") as lf:
                    lf.write(json.dumps(sample) + "\n")
            except OSError:
                pass
            # Print every second. One host: show host load once + in-pod CPU/mem for stack (Synapse etc.) vs clients (loadtest pods).
            # Containers don't have loadavg; we use kubectl top pod CPU/mem for stack vs clients.
            reported = max(load_window) if load_window else (load1 if load1 is not None else 0.0)
            load_str = ""
            if orchestrator_same_as_pods:
                # One host (e.g. kspld0): host load once, then stack pods CPU/mem and client pods CPU/mem (in-pod metrics).
                if local_load1 is not None:
                    load_str += f" host_load={local_load1:.2f}"
                load_str += f" | stack_pods {stack_cpu_m}m {stack_mem_mi}Mi | client_pods {loadtest_cpu_m}m {loadtest_mem_mi}Mi"
            else:
                # Multiple hosts: orchestrator_host, client_node, stack_node (host loadavg per host).
                if local_load1 is not None:
                    load_str += f" orchestrator_host={local_load1:.2f}"
                if load1 is not None:
                    load_str += f" client_node={reported:.2f}"
                if load1_stack_node is not None:
                    load_str += f" stack_node={load1_stack_node:.2f}"
                    total_load = (reported if load1 is not None else 0) + load1_stack_node
                    if total_load > 0:
                        load_str += f" total={total_load:.2f}"
                load_str += f" | stack_pods {stack_cpu_m}m {stack_mem_mi}Mi | client_pods {loadtest_cpu_m}m {loadtest_mem_mi}Mi"
            if not load_str.strip():
                load_str = " load=n/a"
            mem_str = f" node_mem={node_mem_mb}MB" if node_mem_mb is not None else ""
            srv_str = f" server={server_status} {server_latency_ms}ms" if server_status is not None else ""
            pod_str = f" | SERVER {stack_pod_n}p | CLIENTS {running}p"
            # When waiting to add next participant, show countdown on same line every second so 1r0p doesn't look stuck.
            next_str = ""
            if next_to_start < max_p:
                due = (next_to_start - min_p + 1) * step_dur
                sec_until = max(0, int(due - elapsed))
                if sec_until > 0:
                    next_str = f" | next+1 in {sec_until}s"
                else:
                    next_str = " | next+1 now"
            # Show started vs active so it's clear we didn't "start 1 job" when 4 of 5 failed right away
            if running > peak_running:
                peak_running = running
                if peak_running >= 2:
                    print(f"[safety] peak so far: {peak_running}r (target: all {max_p} in parallel)", file=sys.stderr)
            # Track when we first had 6+ jobs so we don't dump the instant the 6th pod is ContainerCreating.
            if jobs_created >= 6 and first_time_6_jobs is None:
                first_time_6_jobs = elapsed
            # If we're stuck at 5r (or similar) despite 6+ jobs for 30s+, dump why once then interpret and stop.
            stuck_duration = (elapsed - first_time_6_jobs) if first_time_6_jobs is not None else 0
            if (
                not stuck_at_5r_dumped
                and jobs_created >= 6
                and running <= 5
                and elapsed >= 90
                and stuck_duration >= STUCK_GRACE_AFTER_6_JOBS_SEC
            ):
                stuck_at_5r_dumped = True
                print(f"[ramp] Running stuck at {running}r despite {jobs_created} jobs for {stuck_duration:.0f}s. Dumping WHY to results/job_logs.txt", file=sys.stderr)
                _k8s_dump_why_no_pods(namespace, job_prefix, jobs_created, job_logs_path)
                _k8s_dump_job_logs(namespace, job_prefix, [5, 6] if jobs_created > 6 else list(range(jobs_created)), tail=100, log_file=job_logs_path, quiet=True)
                _k8s_interpret_stuck_pods(namespace, job_prefix)
                print(f"[ramp] Stopping ramp; fix the cause above then re-run.", file=sys.stderr)
                ramp_safety_triggered = True
                break
            jobs_str = f"started={jobs_created} active={active} ok={job_succeeded} failed={job_failed} | pods={running}r{pending}p"
            print(f"[safety] t={elapsed:.0f}s {jobs_str} |{load_str}{mem_str}{srv_str}{pod_str}{next_str} max={load1_max}", file=sys.stderr)
            if active < jobs_created and jobs_created > 1:
                if not job_logs_dumped_for_early_exits:
                    job_logs_dumped_for_early_exits = True
                    # Dump in background so we don't block the loop (was blocking 30–60s and delaying +1 adds).
                    indices_to_dump = list(range(jobs_created))
                    log_file_path = load_test_dir / "results" / "job_logs.txt"
                    def _dump_async():
                        _k8s_dump_job_logs(namespace, job_prefix, indices_to_dump, tail=150, log_file=log_file_path, quiet=True)
                    threading.Thread(target=_dump_async, daemon=True).start()
                    print(f"  >>> {jobs_created - active} job(s) finished early. See results/job_logs.txt", file=sys.stderr)
                    sys.stderr.flush()
            # Every 5s show proof from each concurrent participant and one sample log line.
            if int(elapsed) % 5 == 0:
                proof_str = _k8s_proof_per_participant(namespace, job_prefix)
                print(f"  proof: {proof_str}", file=sys.stderr)
                sample_pod = _k8s_first_running_pod(namespace, job_prefix)
                if sample_pod:
                    sample_log = _k8s_pod_log_tail(namespace, sample_pod, 6)
                    if len(sample_log) > 140:
                        sample_log = sample_log[:137] + "..."
                else:
                    if active > 0 and running == 0:
                        sample_log = f"(no running pod; {pending} pending - stuck?)"
                    elif job_succeeded + job_failed > 0:
                        sample_log = f"(no running pod; {job_succeeded} succeeded {job_failed} failed)"
                    else:
                        sample_log = "(no running pod)"
                print(f"  sample_log: {sample_log}", file=sys.stderr)
                # Fail immediately on HTTP errors in participant logs
                if any(x in sample_log for x in ("HTTPError", "401", "Unauthorized", "raise_for_status", "Client Error")):
                    print(f"[ramp] FAIL: HTTP error in participant log. Exiting.", file=sys.stderr)
                    _k8s_dump_job_logs(namespace, job_prefix, list(range(min(5, jobs_created))), tail=80, log_file=load_test_dir / "results" / "job_logs.txt")
                    return 1
            if load1 is not None and load1 > load1_max:
                print("SAFETY TRIGGERED: load1 > max", file=sys.stderr)
                ramp_safety_triggered = True
                break
            statuses = _k8s_job_statuses(namespace, job_prefix)
            errors = sum(1 for _, code in statuses if code == 1)
            if errors >= consecutive_errors_max:
                print(f"SAFETY TRIGGERED: {errors} participant errors", file=sys.stderr)
                ramp_safety_triggered = True
                break
            time.sleep(1)
        # Summary: load, latency, I/O (node vs local) for comparison
        _write_ramp_metrics_summary(load_samples_path, results_dir)
        print(f"[result] Peak running during ramp: {peak_running}r (target: all {max_p} in parallel). First started runs longest until ramp end.", file=sys.stderr)
        # Ramp has a designated end: snapshot job results, dump logs if needed, then cancel jobs (don't wait 300s).
        time.sleep(5)
        statuses = _k8s_job_statuses(namespace, job_prefix)
        joined_ok = sum(1 for _, c in statuses if c == 0)
        total_started = len(statuses)
        if peak_running < max_p and total_started >= max_p:
            print(f"[result] Only {peak_running}r despite {max_p} jobs created — check ResourceQuota (kubectl describe resourcequota -n {namespace}) and OOMKilled.", file=sys.stderr)
        # In ramp mode we cancel jobs at the end so they never exit with 0. If we completed without
        # safety trigger and all jobs were still active (no exit code yet), treat as success.
        if not ramp_safety_triggered and total_started > 0 and all(c is None for _, c in statuses):
            joined_ok = total_started
            print(f"[result] ramp completed: all {total_started} participants still active (counted as success).", file=sys.stderr)
        result_path = load_test_dir / ".load_test_result.json"
        with open(result_path, "w") as f:
            json.dump({"joined": joined_ok, "total": total_started, "success_rate_pct": (100.0 * joined_ok / total_started) if total_started else 0}, f)
        if joined_ok < total_started and total_started > 0:
            print(f"[result] {joined_ok}/{total_started} succeeded at ramp end. Job logs:", file=sys.stderr)
            _k8s_dump_job_logs(namespace, job_prefix, list(range(total_started)), tail=100, log_file=load_test_dir / "results" / "job_logs.txt")
            oom_list = _k8s_oom_pods(namespace, pod_prefix=job_prefix)
            if oom_list:
                print(
                    f"[result] RUN INVALID: OOM on pod(s): {oom_list}. Raise participant memory (run_load_test.py Job resources) or quota (k8s-qa/00-budget.yaml).",
                    file=sys.stderr,
                )
        _k8s_delete_jobs(namespace, job_prefix)
        # Skip the long wait block below; we already have result and deleted jobs.
        ramp_done_result = (joined_ok, total_started)
    else:
        ramp_done_result = None
        # Fixed N: create N Jobs at once
        print(f"[k8s] starting {n} participants (duration={duration}s)", file=sys.stderr)
        for i in range(n):
            job_name = f"{job_prefix}{i}"
            yaml_str = _k8s_job_yaml(job_name, i, duration, image, namespace, image_pull_policy, node_name)
            _k8s_apply_job(yaml_str)
        # Wait for duration + buffer
        time.sleep(duration + 30)

    if ramp_done_result is not None:
        joined_ok, total_started = ramp_done_result
    else:
        wait_timeout = duration + 60
        print(f"[k8s] Waiting up to {wait_timeout}s for all jobs to complete ...", file=sys.stderr)
        joined_ok, total_started = _k8s_wait_jobs(namespace, job_prefix, timeout_sec=wait_timeout)
        result_path = load_test_dir / ".load_test_result.json"
        with open(result_path, "w") as f:
            json.dump({"joined": joined_ok, "total": total_started, "success_rate_pct": (100.0 * joined_ok / total_started) if total_started else 0}, f)
        if joined_ok < total_started and total_started > 0:
            print(f"[result] {joined_ok}/{total_started} participants succeeded. Dumping job logs.", file=sys.stderr)
            _k8s_dump_job_logs(namespace, job_prefix, list(range(total_started)), tail=100, log_file=load_test_dir / "results" / "job_logs.txt")

    if we_created_users:
        subprocess.call(
            [sys.executable, str(script_dir / "remove_test_users.py"), "--config", args.config, "--users-file", users_file],
            cwd=load_test_dir,
        )

    if joined_ok < total_started:
        print(f"[result] {joined_ok}/{total_started} participants succeeded", file=sys.stderr)
        return 1
    return 0


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
    parser.add_argument("--k8s-participants", action="store_true", help="Run participants as k8s Jobs in the cluster (in-cluster URLs; no port-forward)")
    parser.add_argument("--k8s-namespace", default="matrix-qa", help="Namespace for load-test ConfigMap/Secret/Jobs (default: matrix-qa)")
    parser.add_argument("--k8s-image", default="load-test-participant:latest", help="Image for participant pods")
    parser.add_argument("--k8s-image-pull-policy", default=None, help="e.g. Never when image is pre-loaded on node (docker save | ssh node docker load)")
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
    prometheus_load1_query = (os.environ.get("PROMETHEUS_LOAD1_QUERY") or safety_cfg.get("prometheus_load1_query") or "").strip() or None
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

    if getattr(args, "k8s_participants", False):
        return _run_k8s_participants(
            args=args,
            config=config,
            n=n,
            duration=duration,
            min_p=min_p,
            max_p=max_p,
            step_dur=step_dur,
            ramp_up=ramp_up,
            room_id=room_id,
            load_test_dir=load_test_dir,
            users_file=users_file,
            we_created_users=we_created_users,
            script_dir=script_dir,
        )

    safety_file = load_test_dir / ".safety_triggered"
    if safety_file.exists():
        safety_file.unlink()
    env = os.environ.copy()
    env["TEST_ROOM_ID"] = room_id
    env["LOADTEST_METRICS_DIR"] = str(load_test_dir)  # participants write .participant_metrics_<i>.json

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

        # Rolling window: report max load over last N samples so we measure when participants are active, not during I/O dips
        LOAD_WINDOW_SIZE = 10
        load_window = collections.deque(maxlen=LOAD_WINDOW_SIZE)
        results_dir = load_test_dir / "results"
        results_dir.mkdir(parents=True, exist_ok=True)
        load_samples_path = results_dir / "load_ramp.jsonl"

        # Loop: every 1s check safety; every step_dur add one participant until max_p
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

            load1, source = get_load1(prometheus_url, safety_load_ssh, load1_query=prometheus_load1_query)
            server_status, server_latency_sec = get_server_latency((config.get("server_url") or "").strip())
            server_latency_ms = int(server_latency_sec * 1000) if server_latency_sec is not None else None
            local_load1 = get_load1_proc()
            procs_live = sum(1 for _, p in procs if p.poll() is None)
            if load1 is not None:
                load_window.append(load1)
            try:
                with open(load_samples_path, "a") as lf:
                    lf.write(json.dumps({
                        "t": round(elapsed, 1), "load1": load1, "source": source,
                        "local_load1": local_load1, "n": next_to_start, "procs_live": procs_live,
                        "server_status": server_status, "server_latency_ms": server_latency_ms,
                    }) + "\n")
            except OSError:
                pass
            # Report max over window so load reflects active participants, not I/O-bound dips
            if load_window and int(elapsed) % 5 < 1:
                reported = max(load_window)
                local_str = f" local_load1={local_load1:.2f}" if local_load1 is not None else " local_load1=n/a"
                srv_str = f" server={server_status} {server_latency_ms}ms" if server_status is not None else ""
                print(f"[safety] t={elapsed:.0f}s load1={reported:.2f} ({source}){local_str}{srv_str} | procs={procs_live}/{next_to_start} live | max={load1_max}", file=sys.stderr)
            if load1 is not None and load1 > load1_max:
                safety_triggered = True
                safety_file.write_text("1")
                break
            errors = sum(1 for _, p in procs if p.poll() is not None and p.returncode != 0)
            if errors >= consecutive_errors_max:
                safety_triggered = True
                safety_file.write_text("1")
                break
            time.sleep(1)

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
            load1, source = get_load1(prometheus_url, safety_load_ssh, load1_query=prometheus_load1_query)
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
    _write_participant_metrics_summary(load_test_dir)

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
