# Testing in Kubernetes

Minimal or full Matrix stack in Kubernetes for QA: Synapse (SQLite or Postgres), optional LiveKit + lk-jwt for Element Call, and a comprehensive headless test suite.

**Run everything from this repo’s root.** Clone the repo if needed, then `cd` into `hardened-matrix-stack-install-from-scratch` so that `./k8s-qa/run-matrix-qa-tests.sh` and `kubectl apply -f k8s-qa/` use the files in this directory.

## kubectl and kubeconfig

`kubectl` must be able to read your cluster config. If you see **permission denied** on the kubeconfig (e.g. k3s’s `/etc/rancher/k3s/k3s.yaml`):

- **Option A:** Copy it to your user and set `KUBECONFIG`:
  ```bash
  sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
  sudo chown "$(whoami):" ~/.kube/config
  export KUBECONFIG=~/.kube/config
  ```
- **Option B:** Use `sudo kubectl` for apply/delete/port-forward.
- **Option C (k3s):** Restart k3s with `--write-kubeconfig-mode 644` so the default kubeconfig is world-readable (see k3s docs).

## What’s in k8s-qa

| File | Purpose |
|------|---------|
| **namespace.yaml** | `matrix-qa` namespace |
| **00-budget.yaml** | Optional: ResourceQuota + LimitRange for 1 vCPU / 1 GiB node; apply with namespace before other manifests. See **SMALL-CLUSTER.md**. |
| **synapse-deployment.yaml** | Synapse pod (init: generate + config + optional Postgres), Service ClusterIP (backend only). |
| **nginx-configmap.yaml** + **nginx.yaml** | nginx reverse proxy: proxy to Synapse, rate-limit login/register, no-federation. Single entrypoint NodePort 30048. |
| **postgres.yaml** | Optional PostgreSQL for Synapse (Deployment + Service + Secret). Synapse uses it when this is applied. |
| **coturn.yaml** | Optional Coturn (TURN/STUN); Synapse gets turn.yaml when this is applied. coturn-test-job verifies port 3478. |
| **livekit.yaml** | Optional LiveKit server + lk-jwt-service for Element Call / MatrixRTC. NodePorts 30049 (WS), 30050 (JWT). |
| **run-matrix-qa-tests.sh** | API tests: versions, nginx (federation block, .well-known, rate limit), metrics, whoami, sync, timeline, register/login, rooms, file upload/download, logout. Supports `MATRIX_QA_TESTS=id1,id2` and `MATRIX_QA_SKIP=id1,id2`; `--list-tests` prints ids. |
| **deploy-only.sh** | Deploy stack + port-forward only (no tests). Run once, then run test subsets (e.g. `run-quick-tests.sh` or `MATRIX_QA_TESTS=metrics run-matrix-qa-tests.sh`) without re-deploying. |
| **run-quick-tests.sh** | Run only quick/smoke tests: versions, federation (blocked or allowed), wellknown client, metrics. |
| **run-e2e-qa.sh** | Full E2E: runs API tests, then (if LiveKit URLs set) headless call tests (3–5 participants, video+audio) |
| **port-forward-and-test.sh** | Port-forward nginx to localhost:30048, run API tests, then stop forward |
| **deploy-and-test.sh** | Deploy all manifests, wait for Ready, then run E2E (with port-forward if no BASE_URL). If Secret `msmtp-credentials` exists, runs optional email test. |
| **run-full-qa-two-phase.sh** | **Full front-to-back:** Phase 1 = deploy with **no federation**, run all tests (API, Coturn, LiveKit/calls, moderation bots, optional email). Phase 2 = enable federation (apply nginx-configmap-federation), run federation + blocklist tests (`.well-known/matrix/server`, federation allowed, subscribe Draupnir to CME). Creates `matrix-qa-admin` Secret if missing so moderation bots run. |
| **send-test-email.sh** | Optional: send one test email from the cluster (verifies msmtp/alert path; same path fail2ban uses on VM). Requires Secret; see below. |
| **send-test-email-job.yaml** + **send-test-email-configmap.yaml** | Job + script to send one email via Gmail SMTP. No secrets in repo. |
| **moderation-bots-setup-job.yaml** | One-time Job: create admin (if missing), @draupnir/@mjolnir, management rooms; outputs tokens for Secrets. |
| **create-moderation-secrets-from-job.sh** | After setup Job completes, parses log and creates Secrets draupnir-config, mjolnir-config. |
| **draupnir.yaml** + **mjolnir.yaml** | Draupnir and Mjolnir Deployments (config from Secrets). |
| **ensure-moderation-bots-configmap.yaml** + **ensure-moderation-bots-cronjob.yaml** | Script + CronJob: add bots to all rooms and make them room admins (every 10 min). |
| **ensure-moderation-bots-in-rooms.sh** | Standalone script (same logic as CronJob); for VM or one-off run. |
| **nginx-configmap-federation.yaml** | Optional: nginx config with federation allowed and .well-known/matrix/server for federation tests. |
| **TEST-MATRIX.md** | Full test matrix: every feature and workflow (auth, rooms, E2EE, file share, voice/video calls, moderation bots, optional email) |
| **SMALL-CLUSTER.md** | Running on 1 vCPU / 1 GiB: minikube flags, resource budget (00-budget.yaml), per-component limits, load-test tips for calls. |

## Deploy

From the repo root, with `kubectl` and `KUBECONFIG` pointing at your cluster:

```bash
# Full stack (Synapse + Postgres + LiveKit + lk-jwt)
kubectl apply -f k8s-qa/
```

If you apply the whole directory, `send-test-email-configmap.yaml` and `send-test-email-job.yaml` are included; the Job runs once. Without the `msmtp-credentials` Secret it will fail (safe to ignore or delete the job). To deploy without the email Job, apply only: `namespace.yaml`, `postgres.yaml`, `synapse-deployment.yaml`, `nginx-configmap.yaml`, `nginx.yaml`, `coturn.yaml`, `livekit.yaml`. `deploy-and-test.sh` applies that set.

- **Moderation bots (Draupnir + Mjolnir):** Create Secret `matrix-qa-admin` with key `admin-password`, then run `deploy-and-test.sh` (or apply moderation-bots-setup-job, wait for completion, run `create-moderation-secrets-from-job.sh`, then apply draupnir.yaml, mjolnir.yaml, ensure-moderation-bots-configmap, ensure-moderation-bots-cronjob). Bots are added to all rooms and made room admins by the CronJob. To run the moderation-bots test: `MODERATION_BOTS_TEST=1 MATRIX_QA_ADMIN_PASSWORD=<admin-pass> ./k8s-qa/run-matrix-qa-tests.sh`.
- **Federation (optional):** Apply `nginx-configmap-federation.yaml` and restart nginx to allow `/_matrix/federation` and serve `/.well-known/matrix/server`. **When federating, subscribe Draupnir/Mjolnir to at least one community policy list** (see repo `COMMUNITY-POLICY-LISTS.md`). Default list: `#community-moderation-effort-bl:neko.dev` (CME). In management room: `!draupnir watch #community-moderation-effort-bl:neko.dev` or use `subscribe-draupnir-community-lists.sh`. Test 30 sends the watch command and asserts success.
- **Minimal (Synapse + nginx):** Apply `namespace.yaml`, `synapse-deployment.yaml`, `nginx-configmap.yaml`, `nginx.yaml`. All client traffic goes through nginx (NodePort 30048) so we QA proxy, rate-limit, and no-federation.
- **With Postgres:** Also apply `postgres.yaml`. Synapse init will detect the postgres Secret and use PostgreSQL.
- **With LiveKit (calls):** Also apply `livekit.yaml`. Expose NodePorts 30049 (LiveKit WS) and 30050 (lk-jwt).

Wait until pods are ready:

```bash
kubectl get pods -n matrix-qa -w
```

First run can take 1–2 minutes (init generates config and signing keys; Postgres must be up before Synapse if used).

## Access

- **NodePort (on the node or same network):**  
  Matrix (via nginx): `http://<node-ip>:30048`  
  LiveKit WS: `ws://<node-ip>:30049`  
  lk-jwt: `http://<node-ip>:30050`
- **Port-forward (from any machine with kubectl):**
  ```bash
  kubectl port-forward -n matrix-qa svc/nginx 30048:80
  kubectl port-forward -n matrix-qa svc/livekit 30049:7880
  kubectl port-forward -n matrix-qa svc/lk-jwt 30050:6080
  ```
  Then use `http://localhost:30048`, `ws://localhost:30049`, `http://localhost:30050`. All Matrix API traffic goes through nginx (proxy, rate-limit, no-federation).

## Run tests

Requires: `curl`, `jq`, `openssl`. For call tests: Python 3.10+ and `load-test/requirements.txt`.

### API + multi-user + file tests (no LiveKit)

From the repo root:

```bash
# If you’re on the node or already port-forwarding to 30048:
./k8s-qa/run-matrix-qa-tests.sh

# Port-forward and run in one go
./k8s-qa/port-forward-and-test.sh

# Custom URL
MATRIX_BASE_URL=http://localhost:9000 ./k8s-qa/run-matrix-qa-tests.sh
```

### Full E2E (API + call tests)

Set LiveKit URLs so call tests run (headless 3–5 participants, video+audio):

```bash
# With port-forward (default)
./k8s-qa/deploy-and-test.sh

# Or manually: port-forward, then
MATRIX_BASE_URL=http://localhost:30048 \
LIVEKIT_WS_URL=ws://localhost:30049 \
LIVEKIT_JWT_URL=http://localhost:30050 \
MATRIX_QA_SERVER_NAME=qa.local \
./k8s-qa/run-e2e-qa.sh

# With NodePort (replace <node-ip>)
MATRIX_BASE_URL=http://<node-ip>:30048 \
LIVEKIT_WS_URL=ws://<node-ip>:30049 \
LIVEKIT_JWT_URL=http://<node-ip>:30050 \
./k8s-qa/run-e2e-qa.sh
```

If you overrode `registration_shared_secret` in the cluster:

```bash
MATRIX_REGISTRATION_SHARED_SECRET=your-secret ./k8s-qa/run-matrix-qa-tests.sh
```

Exit code 0 = all tests passed.

### Run only some tests (faster iteration)

Deploy once, then run a subset of tests repeatedly without re-deploying:

```bash
# 1) Deploy and start port-forward (no tests). Script stays in foreground (Ctrl+C stops port-forwards).
./k8s-qa/deploy-only.sh

# 2) In another terminal (or after deploy-only, in same shell if you background it): run quick tests only
./k8s-qa/run-quick-tests.sh
# Quick tests = versions, federation_blocked, wellknown_client, metrics (no login/rooms)

# 3) Run a single test by id (e.g. fix metrics, then re-run only that)
MATRIX_QA_TESTS=metrics ./k8s-qa/run-matrix-qa-tests.sh

# 4) Run a few tests by id
MATRIX_QA_TESTS=versions,wellknown_client,metrics ./k8s-qa/run-matrix-qa-tests.sh

# 5) Skip specific tests
MATRIX_QA_SKIP=rate_limit,file_upload ./k8s-qa/run-matrix-qa-tests.sh

# 6) List all test ids
./k8s-qa/run-matrix-qa-tests.sh --list-tests
```

| Script | Purpose |
|--------|---------|
| **deploy-only.sh** | Deploy stack + port-forward; no tests. Use once, then run test subsets in a loop. |
| **run-quick-tests.sh** | Run only versions, federation (blocked or allowed), wellknown client, metrics. |
| **run-matrix-qa-tests.sh** | Full suite; use `MATRIX_QA_TESTS=id1,id2` or `MATRIX_QA_SKIP=id1,id2` to filter. |

## Optional: fail2ban / msmtp email in the workflow

**Credentials are never stored in the repo.** Use a Kubernetes Secret (or env only in CI) so the app password never leaks.

- **In k8s:** The same “alert email” path (Gmail + app password) that fail2ban and Monit use on the VM can be verified from the cluster by sending one test email. Create the Secret once (do not commit it):

  ```bash
  kubectl create secret generic msmtp-credentials -n matrix-qa \
    --from-literal=password=YOUR_GMAIL_APP_PASSWORD \
    --from-literal=alert_email=your@gmail.com
  ```

  Then run `./k8s-qa/send-test-email.sh`, or let `./k8s-qa/deploy-and-test.sh` run it automatically after E2E if the secret exists. The Job sends one “k8s-qa email test” message; check your inbox.

- **Fail2ban triggering:** fail2ban (sshd, matrix-synapse-auth) runs on the **VM** (e.g. after `run-qa-noninteractive.sh` and `setup-email-alerts.sh`). When a ban fires there, fail2ban uses the same msmtp/sendmail path to email you. In k8s we don’t run fail2ban; we only verify that the **email path** works by sending one test email from a Job when you provide credentials via the Secret. So: **k8s QA = “email can be sent”; VM = full fail2ban + email on ban.**

- **Safe use in CI:** In a pipeline, set the app password in a secret/store (e.g. CI secret variable) and create the Secret from env before running deploy-and-test, e.g. `kubectl create secret generic msmtp-credentials -n matrix-qa --from-literal=password="$MSMTP_APP_PASSWORD" --from-literal=alert_email="$ALERT_EMAIL"`. Never log or commit `MSMTP_APP_PASSWORD`.

## Test matrix

See **[TEST-MATRIX.md](TEST-MATRIX.md)** for the full list of test cases: discovery, auth, rooms (encrypted and unencrypted), multi-user messaging, file upload/download, voice/video calls, moderation bots (in-room + admin PL), and community-list subscription (send `!draupnir watch` to management room). All run headless in k8s or on a VM.

**Live integration (VM installer):** The same workflow is used in the repo’s VM installer: when federation is enabled, a moderation bot (Draupnir or Mjolnir) is required; the installer subscribes it to the CME community list. Ensure-bots-in-rooms cron and community list scripts are in the repo root: `ensure-moderation-bots-in-rooms.sh`, `subscribe-draupnir-community-lists.sh`, `subscribe-mjolnir-community-lists.sh`, and [COMMUNITY-POLICY-LISTS.md](../COMMUNITY-POLICY-LISTS.md).

## Teardown

```bash
kubectl delete -f k8s-qa/
```
