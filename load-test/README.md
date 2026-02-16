# Matrix + LiveKit load test

Headless A/V load test for a Matrix server with Element Call (LiveKit): synthetic participants join a **private E2EE** test room (only you + test bots), publish synthetic audio and video, and an orchestrator runs a **safety kill switch** (stop all bots if load or error thresholds are exceeded).

## Setup

1. Copy `config.example.yaml` to `config.yaml` and fill in:
   - `server_url`, `server_name`
   - `admin_user_id`, `admin_access_token` (get token from Element: Settings → Help & About → Access Token, or see below)
   - `livekit_ws_url`, `livekit_jwt_url` (e.g. `wss://matrix.timeways.net/livekit/sfu`, `https://matrix.timeways.net/livekit/jwt/`)
   - Optionally `safety.prometheus_url` for load-based safety (Netdata at /metrics/ doesn't expose Prometheus API—use `safety_load_ssh` for server load)
2. Do **not** commit `config.yaml`, `test_users.json`, or `.env`.

### Run from your machine (orchestrator + all participants local)

**Orchestrator and participants run on your laptop**; they talk to the server over the public URLs. The server only sees normal client load (no extra processes on the box).

1. **Fetch admin token** (for creating test users/room; Admin API is localhost-only on server, so we use a tunnel only for that step):
   ```bash
   ./get-admin-token-from-remote.sh lukano@timeways.net
   ```

2. **Config:** `config.yaml` should have `server_url: "https://matrix.timeways.net"` (and `livekit_ws_url` / `livekit_jwt_url` pointing at the server). Set `safety.safety_load_ssh: "lukano@timeways.net"` so the safety loop reads the **server’s** load via SSH and backs out when it exceeds `load1_max`.

3. **First run (create users + room):** Start a tunnel so the create step can hit the Admin API, then run the test. Participants will use the public URL from config.
   ```bash
   ssh -f -N -L 8008:127.0.0.1:8008 lukano@timeways.net
   SERVER_URL=http://127.0.0.1:8008 ./run.sh --participants 4 --duration 120
   pkill -f "ssh.*8008:127.0.0.1:8008"
   ```
   If the tunnel fails (connection reset), create users/room once from the server (see “Run on the server” below), then use `--no-create-users` and set `test_room_id` / `TEST_ROOM_ID` from your machine.

4. **Later runs** (reuse existing users/room): no tunnel needed if `test_users.json` and `test_room_id.txt` (or `test_room_id` in config) exist:
   ```bash
   ./run.sh --no-create-users --participants 4 --duration 120
   ```

### Run on the server (alternative)

If you prefer to run everything on the server: copy `config.example.yaml` to `config.yaml`, set `server_url: "http://127.0.0.1:8008"` and `admin_access_token` (e.g. from `~/mjolnir-production.yaml`), and run `./run-on-server.sh` or `./run.sh` there. Leave `safety_load_ssh` unset so safety uses local `/proc/loadavg`.

## Run

```bash
./run.sh --participants 10 --duration 300
```

Or with metrics collection (writes `metrics.jsonl`):

```bash
./run.sh --participants 10 --duration 300 --collect-metrics
```

- **Exit 0**: Ran for the full duration without safety trigger.
- **Exit 2**: Safety triggered (load or participant errors exceeded thresholds); all bots were stopped.

First run will **create** test users and a private E2EE room (invite-only; only `admin_user_id` and the test bots). When the run finishes, **test users are deactivated** (removed) if they were created in that run. Reuse with existing users/room by ensuring `test_users.json` and `test_room_id.txt` (or `test_room_id` in config) exist, or pass `--no-create-users` and set `TEST_ROOM_ID` / `test_room_id` (in that case users are not deactivated at the end).

## Small nodes (1 vCPU / 1 GiB) — applies to the **server/k8s stack only**

The 1c/1g resource limit refers to the **Matrix stack in k8s** (Synapse, LiveKit, nginx, etc.). The **host running the load test** (orchestrator + participant processes) can use full CPU, memory, and parallelism. Use `--start-stagger 0` to start all participants at once and load the stack as hard as your machine allows (within reason; leave some headroom).

On constrained **clusters or VPS** (the stack under test), use fewer participants and shorter duration to avoid OOM or safety triggers:

- `--participants 2` or `3`, `--duration 60` or `120`
- The scripts use 320×240 @ 15 fps video and synthetic audio; for even lighter load, you can reduce resolution/fps in `participant.py` or run LiveKit’s own `lk load-test` with `--video-resolution low --no-simulcast` (see docs/SMALL-CLUSTER.md).

## Scaling and capacity (what the tests tell you)

After a k8s ramp (e.g. 1→10), the run prints and writes **per-participant load** so you know how much each user adds:

- **results/ramp_metrics_summary.json** — `per_participant`: `cpu_m` (millicores), `mem_mi` (MiB), `load1_added_per_user` (incremental node load per additional user); and `peak_n` (max participants in the run). The console also prints a line like: `per participant (at peak n=10): ~170 mCPU, ~90 Mi, ~0.4 load1 added per user. Scale: node load1 hits load1_max or quota.`
- **How far you can scale:** In practice you’re limited by (1) **node load1** — ramp until `load1` hits `safety.load1_max` (e.g. 20), then approximate max users ≈ `(load1_max - baseline_load1_node) / load1_added_per_user`; (2) **k8s ResourceQuota** — namespace CPU/memory limit (see `k8s-qa/00-budget.yaml` and the “Max participants from quota” line at ramp start); (3) **OOM or scheduler** — if pods stay Pending or get OOMKilled, increase quota or add nodes.

These numbers are for the **test profile** (480p24 A/V, one Matrix message per 15s). Heavier clients (higher res, more messages) will add more load per user.

**Why load1 may not look linear:** Node load1 is a 1-minute exponential average, so it lags real CPU and can jump (e.g. spike around 10–12 participants) or dip near ramp end. Use the per-participant `load1_added_per_user` and peak-n summary for capacity planning; plot `load_ramp.jsonl` (load1 vs `n` or `t`) to inspect actual shape.

## Safety

- If `safety.load1_max` is set and Prometheus (or SSH /proc/loadavg when prometheus_url empty) returns load1 above it, the orchestrator writes a stop signal and all participants disconnect; exit code 2.
- If the number of participant processes that have exited with an error reaches `safety.consecutive_errors_max`, same behaviour.
- A `.safety_triggered` file is written when stopping so participants can exit promptly.

## Ramp harness (2 → N participants, metrics + summary)

For structured load ramps (e.g. 1c/1g validation): run Tier 1 (LiveKit SDK) and optionally Tier 2 (Playwright Element Call) for each participant count, sample metrics every 2s, and write `results/summary.csv`.

### What the ramp actually does (Tier 1)

- **Test accounts:** `@test-load-1:<server_name>`, `@test-load-2:<server_name>`, … (from `create_test_users.py`; `<server_name>` is e.g. `qa.local` from config). They join one private E2EE room and stay in it for the run.
- **Text (Matrix):** Yes. Each participant sends **one Matrix message every 15 seconds** (rotating through short sentences) so the server is under chat + media load.
- **Audio:** Yes. Each participant publishes **continuous synthetic audio** to LiveKit: 48 kHz mono sine wave (440 Hz), 20 ms frames (~50 frames/s), for the full duration.
- **Video:** Yes. Each participant publishes **continuous synthetic video** to LiveKit: 320×240 RGB24, 15 fps moving bar pattern, for the full duration.
- **RX validation:** When N > 1, each participant must be **receiving** at least one remote audio track and one remote video track (subscribed from another participant) within 30s of publishing; otherwise the run fails. Solo (N = 1) runs skip this check.

So each participant is under both **TX** (sending A/V + text) and **RX** (receiving others’ A/V) load. Load (e.g. staying under 2.0 with 7+ participants) reflects real media and chat load, not idle connections.

**Proof of received:** The ramp prints per-participant proof lines (e.g. `p-0 4493v 9474a rx:38000v 80000a`) showing **sent** and **received** frame counts. Longest-running participants (e.g. p-0) should show the **highest cumulative received** (most time in call); each extra peer adds (N−1) inbound A/V streams, so received counts scale with both duration and participant count.

**Client metrics (429s, latency):** When the orchestrator sets `LOADTEST_METRICS_DIR` (it does for local runs), each participant writes `.participant_metrics_<index>.json` on exit with per-operation events: `matrix_join`, `openid_token`, `livekit_token`, `livekit_connect`, and the first `matrix_send`. Each event has `status`, `429_count`, and `latency_ms`. Use these to see server 429s and client-observed RTT/latency.

**Load samples:** During a ramp, each load reading is appended to `results/load_ramp.jsonl` (one JSON object per line: `t`, `load1`, `source`, `n`). Plot `load1` vs `t` or `n` to verify load increases with participant count.

**Faster ramp:** Use `--step-duration-min 10` and/or `--ramp-fast` for a quicker ramp (less time between adding participants). Use `--safety-interval 1` (default) so load is checked every second.

**Requirements:** Base deps + Playwright for Tier 2:

```bash
pip install -r requirements.txt -r requirements-ramp.txt
playwright install chromium
```

**Metrics sampler (Kubernetes):** From a machine with `kubectl` configured, sample node/pod metrics and OOM/restarts every 2s into `results/metrics.jsonl`:

```bash
python scripts/metrics_sampler_k8s.py --namespace matrix-qa --interval 2 --output results/metrics.jsonl
# Stop with Ctrl+C when the load run finishes.
```

**Tier 2 (Playwright):** N headless Chromium browsers with fake media join the same Element Call room URL, collect `getStats()` every 5s into `results/webrtc_stats.jsonl`. Use a guest/public room link, or pass `--tokens-file test_users.json` if your setup supports token-based join:

```bash
python scripts/tier2_element_call_playwright.py --room-url "https://call.element.io/!roomId:server" --participants 3 --duration 180 --output results/webrtc_stats.jsonl
```

**Ramp (Tier 1 + optional Tier 2 + summary):** With `KUBECONFIG` set so the metrics sampler can run, and with `test_users.json` / `test_room_id.txt` from a prior run. The room must be joinable by the test users (create a **public** room or invite the test users to a private room). Use the load-test venv so Tier 1 has the `livekit` package: `cd load-test && .venv/bin/python3 scripts/ramp_harness.py ...`.

```bash
# Tier 1 only (no Playwright), N=2..5, 3 min per N, 60s cooldown
python scripts/ramp_harness.py --config config.yaml --min 2 --max 5 --tier1-duration 180 --skip-tier2

# With Tier 2 and Element Call room URL
python scripts/ramp_harness.py --config config.yaml --min 2 --max 4 --room-url "https://call.element.io/!xxx:server" --tier1-duration 180 --tier2-duration 180
```

Output: `results/summary.csv` with columns `n`, `mode`, `join_success_rate`, `peak_cpu`, `peak_rss_total`, `oom_kills`, `restarts`, `avg_rtt_ms`, `packet_loss_pct`, `tier1_exit`, `notes`. The harness stops early if OOM kills are detected or join success drops below 90%.

### Running participants in Kubernetes (no port-forward)

You can run the **participants** (test bots) as Jobs inside the same cluster as the Matrix stack. That removes the port-forward bottleneck and gives real in-cluster load.

**Load when using k8s participants:** We report **load1_node** = the node where loadtest pods run (SSH to `safety_load_ssh` → `/proc/loadavg`). **load1_local** = orchestrator machine. When the orchestrator runs on the same host as the pods, those two match; when it runs elsewhere, they differ. So **load for the host running the pods** is load1_node; we do not report a separate “server” load unless the stack runs on a different node. Set `safety.safety_load_ssh` to the node where the **pods** run. If the **stack** (Synapse, LiveKit, etc.) runs on a different node, set `safety.stack_load_ssh` to that node so we report **load1_stack_node** as well (then load for the k8s-qa server host and load for the host running the pods are distinct). At ramp start we print which hostname each load comes from. When orchestrator and pods node are the **same host**, we show one **host_load** with “1 node: harness+pods+stack” (that load includes Synapse when the stack runs there). When different, we show **orchestrator=**, **client_node=**, **stack_node=** (if set), and **total** / fractions. **401/get_token:** Check `kubectl logs -n matrix-qa -l app=lk-jwt --tail=100`; run-ramp-k8s patches lk-jwt to nginx so OpenID userinfo is reachable. **OOM:** Raise participant memory or quota (k8s-qa/00-budget.yaml) if runs are invalid.

1. **Build the participant image** (from repo root or `load-test/`):
   ```bash
   docker build -t load-test-participant:latest load-test/
   ```
   If your cluster uses a local daemon (minikube, k3d): point Docker at it first, e.g. `eval $(minikube docker-env)` then build. For Kind: `kind load docker-image load-test-participant:latest`.

2. **Create users and room** once (from your machine, with port-forward or in-cluster access to the Matrix Admin API). Ensure `test_users.json` and `test_room_id.txt` (or `TEST_ROOM_ID`) exist in `load-test/`.

3. **Run the ramp with participants in k8s:**
   ```bash
   cd load-test
   .venv/bin/python3 scripts/ramp_harness.py --config config-ramp-qa.yaml --min 2 --max 10 --single-pass --skip-tier2 --k8s-participants --namespace matrix-qa
   ```
   The harness runs locally and creates ConfigMaps/Secret and one Job per participant in `--namespace`; pods use in-cluster URLs (e.g. `http://nginx.matrix-qa.svc`). Use `--k8s-image` if your image has a different name or tag.

4. **Fixed N (no ramp)** with k8s participants:
   ```bash
   .venv/bin/python3 scripts/run_load_test.py --config config-ramp-qa.yaml --no-create-users --participants 10 --duration 120 --k8s-participants --k8s-namespace matrix-qa
   ```

### Quick reference (k8s ramp)

- **1→20 ramp, 9s step, 1080p:** Set `video_resolution: "1080p"` in `config-ramp-qa.yaml`, then:
  ```bash
  ./run-ramp-k8s.sh   # or: .venv/bin/python3 scripts/ramp_harness.py --config config-ramp-qa.yaml --min 1 --max 20 --step-duration-min 9 --single-pass --skip-tier2 --k8s-participants --namespace matrix-qa
  ```
- **Results:** `results/ramp.log`, `results/load_ramp.jsonl`, `results/ramp_metrics_summary.json`, `results/job_logs.txt` (if jobs exit early).
- **Last ramp verdict:** `python3 scripts/show_ramp_verdict.py` (run from `load-test/`).

## Optional: evaluate metrics

After a run with `--collect-metrics`:

```bash
python3 scripts/evaluate.py --metrics metrics.jsonl --max-load1 2.0
```

Exit 0 = pass (max load1 ≤ threshold), 1 = fail.
