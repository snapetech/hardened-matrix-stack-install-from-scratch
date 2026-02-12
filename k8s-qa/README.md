# Testing in Kubernetes

Minimal Synapse deployment for QA: run the Matrix stack test suite against a Synapse instance in any Kubernetes cluster (k3s, kind, minikube, EKS, etc.).

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

- **namespace.yaml** — `matrix-qa` namespace.
- **synapse-deployment.yaml** — One Synapse pod (init containers generate config + signing keys and set a known `registration_shared_secret`), Service (NodePort 30048), and Secret.
- **run-matrix-qa-tests.sh** — Test script: client versions, register (Admin API shared secret), create room, send message, logout.
- **port-forward-and-test.sh** — Port-forward Synapse to localhost:30048, run the test script, then stop the forward (for use when not on the cluster node).

## Deploy

From the repo root, with `kubectl` and `KUBECONFIG` (or default `~/.kube/config`) pointing at your cluster:

```bash
kubectl apply -f k8s-qa/
```

Wait until the pod is running and ready:

```bash
kubectl get pods -n matrix-qa -w
```

First run can take 1–2 minutes (init generates config and signing keys). When `READY` is `1/1`, Synapse is up.

## Access

- **NodePort (on the node or same network):** `http://<node-ip>:30048`.
- **Port-forward (from any machine with kubectl):**
  ```bash
  kubectl port-forward -n matrix-qa svc/synapse 30048:8008
  ```
  Then use `http://localhost:30048`.

## Run tests

Requires: `curl`, `jq`, `openssl`.

From the repo root:

```bash
# If you’re on the node or already port-forwarding to 30048:
./k8s-qa/run-matrix-qa-tests.sh

# From another machine: port-forward and run tests in one go
./k8s-qa/port-forward-and-test.sh

# Custom URL (e.g. different port or host):
MATRIX_BASE_URL=http://localhost:9000 ./k8s-qa/run-matrix-qa-tests.sh
./k8s-qa/run-matrix-qa-tests.sh http://192.168.1.10:30048
```

If you overrode `registration_shared_secret` in the cluster, set it when running tests:

```bash
MATRIX_REGISTRATION_SHARED_SECRET=your-secret ./k8s-qa/run-matrix-qa-tests.sh
```

Exit code 0 = all tests passed.

## Teardown

```bash
kubectl delete -f k8s-qa/
```
