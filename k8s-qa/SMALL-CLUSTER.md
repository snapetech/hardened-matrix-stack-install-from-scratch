# Running k8s-qa on 1 vCPU / 1 GiB (small VPS / minikube)

Use this when you want to test the full stack (Synapse, Postgres, nginx, Coturn, LiveKit) on a single small node, or to validate resource usage before deploying to a constrained VPS.

## 1. Start a constrained cluster

**Minikube (single node):**

```bash
minikube start --driver=docker --cpus=1 --memory=1024mb
```

Disable heavy addons if you need headroom: `minikube addons disable dashboard` (and optionally `metrics-server`). k3d is often lighter than minikube if the default kube-system footprint is too large.

## 2. Apply the resource budget (optional but recommended)

Apply the quota and limit range so the stack cannot exceed 1c/1g (namespace must exist first):

```bash
kubectl apply -f k8s-qa/namespace.yaml
kubectl apply -f k8s-qa/00-budget.yaml
```

Then deploy the rest of k8s-qa. If you hit quota errors, reduce replica counts or resource requests in the manifests. Verify:

```bash
kubectl describe quota -n matrix-qa
kubectl describe limitrange -n matrix-qa
```

## 3. Per-component resource guide (Profile A — hard cap)

Target requests/limits that fit under the quota:

| Component   | CPU req | CPU lim | Mem req | Mem lim |
|------------|---------|---------|---------|---------|
| Synapse    | 150m    | 350m    | 240Mi   | 380Mi   |
| Postgres   | 50m     | 150m    | 120Mi   | 170Mi   |
| Nginx      | 10m     | 50m     | 25Mi    | 50Mi    |
| Coturn     | 10m     | 100m    | 25Mi    | 70Mi    |
| LiveKit    | 150m    | 300m    | 120Mi   | 200Mi   |
| lk-jwt     | 10m     | 50m     | 25Mi    | 50Mi    |
| **Totals** | **380m**| **1000m**| **555Mi**| **920Mi**|

The existing k8s-qa manifests already set `resources.requests` (and some limits). For a strict 1c/1g test, patch deployments to match the table above, or use a kustomize overlay.

**Profile B (better call quality):** Keep the same memory limits, but omit CPU *limits* for Synapse and LiveKit so they can burst; keep CPU *requests* as above.

## 4. Load testing calls on a small node

To avoid overloading 1 vCPU during call tests:

- Use **low resolution** and **no simulcast** in load tests.
- Prefer **fewer video publishers** (e.g. 2–3) and more subscribers if you need many participants.

**LiveKit CLI load-test (if available):**

```bash
lk load-test --duration 3m --room test-room --video-resolution low --no-simulcast --video-publishers 2 --subscribers 4
```

The repo’s `load-test/` scripts (Element Call / MatrixRTC) can be run with fewer participants and shorter duration when targeting 1c/1g; reduce `duration_seconds` and `participants` in the config.

## 5. Synapse / Postgres tuning for small boxes (VM installs)

On a 1 GB VM (non-k8s), consider:

- **Synapse:** `enable_search: false` to disable message search indexing; reduce presence usage if acceptable; tune `caches.global_factor` to lower RAM (see Synapse config docs).
- **Postgres:** Lower `max_connections`; set Synapse DB pool to `cp_min: 2`, `cp_max: 5` to match.
- **Monitoring:** Throttle or disable Netdata when not debugging so observability doesn’t consume a large share of 1 vCPU.

These are optional; the installer does not change them by default.
