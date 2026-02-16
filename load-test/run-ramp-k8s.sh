#!/usr/bin/env bash
# Build participant image and run ramp with participants in k8s (no port-forward).
# Prereqs: KUBECONFIG set, test_users.json and test_room_id.txt in load-test/ (run create_test_users once).
# Usage: ./run-ramp-k8s.sh [ramp_harness.py args...]
# Example: ./run-ramp-k8s.sh --config config-ramp-qa.yaml --min 2 --max 10 --single-pass --skip-tier2
# For minikube: MINIKUBE_DOCKER=1 ./run-ramp-k8s.sh ...
# For remote cluster: script auto-preloads image to node from config safety_load_ssh (docker save | ssh node docker load) and uses imagePullPolicy: Never.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f test_users.json ] || [ ! -f test_room_id.txt ]; then
  echo "Missing test_users.json or test_room_id.txt. Create users and room first, e.g.:" >&2
  echo "  (with port-forward) .venv/bin/python3 scripts/create_test_users.py --config config-ramp-qa.yaml --participants 20 --force" >&2
  exit 1
fi

if [ -n "${MINIKUBE_DOCKER:-}" ]; then
  if command -v minikube >/dev/null 2>&1; then
    eval "$(minikube docker-env)"
  fi
fi
echo "Building participant image load-test-participant:latest ..."
docker build -t load-test-participant:latest .

PRELOAD_DONE=""
NODE="${LOADTEST_PRELOAD_NODE:-}"
if [ -z "$NODE" ] && [ -f config-ramp-qa.yaml ]; then
  NODE=$("$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml
try:
    c = yaml.safe_load(open('config-ramp-qa.yaml'))
    print((c.get('safety') or {}).get('safety_load_ssh') or '')
except Exception:
    print('')
" 2>/dev/null || true)
fi
if [ -n "$NODE" ] && [ "$NODE" != "localhost" ]; then
  echo "Preloading image on $NODE (k3s containerd so kubelet can use it, no registry) ..." >&2
  # k3s uses its own containerd; must use 'k3s ctr images import', not system ctr
  if docker save load-test-participant:latest | ssh -o ConnectTimeout=10 -o BatchMode=yes "$NODE" 'sudo k3s ctr images import -' 2>/dev/null; then
    PRELOAD_DONE=1
    echo "Image imported into k3s containerd on $NODE." >&2
  else
    # Fallback: Docker load (if node uses Docker runtime) or system ctr
    if docker save load-test-participant:latest | ssh -o ConnectTimeout=10 -o BatchMode=yes "$NODE" docker load 2>/dev/null; then
      PRELOAD_DONE=1
    fi
    if [ -z "$PRELOAD_DONE" ]; then
      echo "Preload failed (need passwordless ssh and 'sudo k3s ctr images import -' on $NODE). Continuing anyway." >&2
    fi
  fi
fi

export TEST_ROOM_ID="$(cat test_room_id.txt)"
VENV_PY="$SCRIPT_DIR/.venv/bin/python3"
[ -x "$VENV_PY" ] || { echo "Create venv: python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"; exit 1; }

# --- Ensure stack is ready so lk-jwt can validate OpenID ---
# Quota: compute max participants from headroom (100m each + 100m buffer). Run that max, or max-1 on failure.
NS="${LOADTEST_K8S_NAMESPACE:-matrix-qa}"
K8S_QA_DIR="${K8S_QA_DIR:-$SCRIPT_DIR/../k8s-qa}"
ROLLOUT_TIMEOUT="${LOADTEST_ROLLOUT_TIMEOUT:-45}"
MAX_PARTICIPANTS=0
dump_deployment_logs() {
  local name=$1
  echo "" >&2
  echo "=== $name rollout failed: dumping pods and logs ===" >&2
  kubectl get pods -n "$NS" -l "app=$name" -o wide 2>&1 | sed 's/^/  /' >&2
  kubectl get events -n "$NS" --field-selector "involvedObject.name=deployment/$name" --sort-by='.lastTimestamp' 2>&1 | tail -20 | sed 's/^/  /' >&2
  for pod in $(kubectl get pods -n "$NS" -l "app=$name" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    echo "--- describe pod $pod ---" >&2
    kubectl describe pod "$pod" -n "$NS" 2>&1 | sed 's/^/  /' >&2
    echo "--- logs $pod ---" >&2
    kubectl logs "$pod" -n "$NS" --all-containers=true --tail=80 2>&1 | sed 's/^/  /' >&2
  done
  echo "=== end $name dump ===" >&2
}
if [ -d "$K8S_QA_DIR" ]; then
  # 0a) Apply budget so quota limit is known (3500m); then check headroom.
  if [ -f "$K8S_QA_DIR/00-budget.yaml" ]; then
    kubectl apply -f "$K8S_QA_DIR/00-budget.yaml" -n "$NS" 2>/dev/null || true
  fi
  # 0b) Quota: normalize to millicores (API may return "5000m" or "5" cores). Per-participant = 100m (LimitRange default).
  # Compute max participants we can run, or fail fast if not enough for 1.
  CPU_PER_PART=100
  BUFFER=100
  MAX_PARTICIPANTS=1
  if kubectl get resourcequota matrix-qa-quota -n "$NS" >/dev/null 2>&1; then
    RAW_USED=$(kubectl get resourcequota matrix-qa-quota -n "$NS" -o jsonpath='{.status.used.limits\.cpu}' 2>/dev/null || echo 0)
    RAW_LIMIT=$(kubectl get resourcequota matrix-qa-quota -n "$NS" -o jsonpath='{.status.hard.limits\.cpu}' 2>/dev/null || echo 0)
    USED=${RAW_USED%m}; [ -z "$USED" ] && USED=0; [[ "$RAW_USED" != *m ]] && [ "$USED" -lt 1000 ] 2>/dev/null && USED=$((USED * 1000))
    LIMIT=${RAW_LIMIT%m}; [ -z "$LIMIT" ] && LIMIT=0; [[ "$RAW_LIMIT" != *m ]] && [ "$LIMIT" -lt 1000 ] 2>/dev/null && LIMIT=$((LIMIT * 1000))
    HEADROOM=$((LIMIT - USED))
    if [ "$HEADROOM" -lt $((CPU_PER_PART + BUFFER)) ] 2>/dev/null; then
      echo "ERROR: ResourceQuota has no headroom (used ${USED}m, limit ${LIMIT}m, need ${CPU_PER_PART}m per participant + ${BUFFER}m buffer)." >&2
      echo "  kubectl describe resourcequota matrix-qa-quota -n $NS" >&2
      exit 1
    fi
    MAX_PARTICIPANTS=$(((HEADROOM - BUFFER) / CPU_PER_PART))
    [ "$MAX_PARTICIPANTS" -lt 1 ] 2>/dev/null && MAX_PARTICIPANTS=1
    [ "$MAX_PARTICIPANTS" -gt 20 ] 2>/dev/null && MAX_PARTICIPANTS=20
    echo "[stack] Quota OK (used ${USED}m / ${LIMIT}m, ${HEADROOM}m headroom). Max participants from quota: $MAX_PARTICIPANTS (${CPU_PER_PART}m each + ${BUFFER}m buffer)." >&2
  fi
  # 1) Create nginx TLS secret if missing
  if ! kubectl get secret nginx-tls-qa -n "$NS" >/dev/null 2>&1; then
    echo "[stack] Creating nginx TLS secret ..." >&2
    TLS_DIR=$(mktemp -d)
    if ! openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout "$TLS_DIR/tls.key" -out "$TLS_DIR/tls.crt" \
      -subj "/CN=qa.local" \
      -addext "subjectAltName=DNS:qa.local,DNS:nginx.$NS.svc,DNS:nginx.$NS.svc.cluster.local" 2>&1; then
      echo "[stack] openssl failed, trying k8s-qa script ..." >&2
      [ -f "$K8S_QA_DIR/nginx-tls-secret-qa.sh" ] && (cd "$K8S_QA_DIR" && NAMESPACE="$NS" bash ./nginx-tls-secret-qa.sh) || true
    else
      kubectl create secret tls nginx-tls-qa --cert="$TLS_DIR/tls.crt" --key="$TLS_DIR/tls.key" -n "$NS" --dry-run=client -o yaml | kubectl apply -f - -n "$NS"
    fi
    rm -rf "$TLS_DIR"
  fi
  if ! kubectl get secret nginx-tls-qa -n "$NS" >/dev/null 2>&1; then
    echo "ERROR: secret nginx-tls-qa missing in $NS." >&2
    exit 1
  fi
  # 2) Apply nginx config/deployment (no pod delete: reload in-place to avoid quota)
  if [ -f "$K8S_QA_DIR/nginx-configmap.yaml" ] && [ -f "$K8S_QA_DIR/nginx.yaml" ]; then
    echo "[stack] Applying nginx config and deployment ..." >&2
    kubectl apply -f "$K8S_QA_DIR/nginx-configmap.yaml" -f "$K8S_QA_DIR/nginx.yaml" -n "$NS" || true
  fi
  # Only reload in place if nginx pod is actually Ready; otherwise recreate so we get a healthy pod.
  NGINX_READY=$(kubectl get pods -n "$NS" -l app=nginx -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  NGINX_POD=$(kubectl get pods -n "$NS" -l app=nginx -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -n "$NGINX_POD" ] && [ "$NGINX_READY" = "True" ]; then
    echo "[stack] Reloading nginx config in place (no new pods) ..." >&2
    kubectl exec -n "$NS" "$NGINX_POD" -- nginx -s reload 2>/dev/null || true
  else
    echo "[stack] Nginx not ready (Ready=$NGINX_READY); recreating pods and waiting for rollout (timeout ${ROLLOUT_TIMEOUT}s) ..." >&2
    kubectl delete pods -n "$NS" -l app=nginx --ignore-not-found=true 2>/dev/null || true
    if ! kubectl rollout status deployment/nginx -n "$NS" --timeout="${ROLLOUT_TIMEOUT}s" 2>&1; then
      dump_deployment_logs nginx
      echo "ERROR: nginx rollout did not complete. See dump above." >&2
      exit 1
    fi
  fi
  # 3) Point lk-jwt at nginx ClusterIP and restart lk-jwt
  NGINX_IP=$(kubectl get svc nginx -n "$NS" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  if [ -n "$NGINX_IP" ] && kubectl get deployment lk-jwt -n "$NS" >/dev/null 2>&1; then
    echo "[stack] Patching lk-jwt hostAliases to nginx $NGINX_IP ..." >&2
    kubectl patch deployment lk-jwt -n "$NS" --type=json \
      -p='[{"op":"replace","path":"/spec/template/spec/hostAliases","value":[{"ip":"'"$NGINX_IP"'","hostnames":["qa.local"]}]}]' || true
  fi
  if kubectl get deployment lk-jwt -n "$NS" >/dev/null 2>&1; then
    echo "[stack] Restarting lk-jwt (timeout ${ROLLOUT_TIMEOUT}s) ..." >&2
    kubectl rollout restart deployment/lk-jwt -n "$NS" || true
    if ! kubectl rollout status deployment/lk-jwt -n "$NS" --timeout="${ROLLOUT_TIMEOUT}s" 2>&1; then
      dump_deployment_logs lk-jwt
      echo "ERROR: lk-jwt rollout did not complete. See dump above." >&2
      exit 1
    fi
  fi
  # Verify nginx is reachable from inside cluster before starting jobs (avoids connection refused).
  echo "[stack] Checking nginx reachable from cluster ..." >&2
  NGINX_URL="http://nginx.${NS}.svc/"
  kubectl run nginx-ready-check --restart=Never -n "$NS" --image=curlimages/curl:latest --overrides='{"spec":{"containers":[{"name":"curl","image":"curlimages/curl:latest","command":["curl","-sf","--max-time","10","'"$NGINX_URL"'"]}]}}' 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    PHASE=$(kubectl get pod nginx-ready-check -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [ "$PHASE" = "Succeeded" ] && break
    [ "$PHASE" = "Failed" ] && break
    sleep 1
  done
  PHASE=$(kubectl get pod nginx-ready-check -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  kubectl delete pod nginx-ready-check -n "$NS" --ignore-not-found=true 2>/dev/null || true
  if [ "$PHASE" != "Succeeded" ]; then
    echo "ERROR: nginx not reachable from cluster ($NGINX_URL). Pod phase=$PHASE." >&2
    echo "  kubectl get pods -n $NS -l app=nginx; kubectl get endpoints nginx -n $NS" >&2
    kubectl get pods -n "$NS" -l app=nginx -o wide 2>&1 | sed 's/^/  /' >&2
    kubectl get endpoints nginx -n "$NS" 2>&1 | sed 's/^/  /' >&2
    dump_deployment_logs nginx
    exit 1
  fi
  echo "[stack] Ready." >&2
fi

EXTRA_ARGS=()
if [ -n "$PRELOAD_DONE" ]; then
  EXTRA_ARGS=(--k8s-image-pull-policy Never)
fi
# If no args and we computed MAX_PARTICIPANTS from quota, run ramp 1..max; on failure retry with max-1.
AUTO_MAX=0
if [ "$MAX_PARTICIPANTS" -gt 0 ] 2>/dev/null && [ $# -eq 0 ]; then
  set -- --config config-ramp-qa.yaml --min 1 --max "$MAX_PARTICIPANTS" --single-pass --skip-tier2
  AUTO_MAX=1
  echo "[ramp] Using quota-derived max: $MAX_PARTICIPANTS participants (no args given)." >&2
fi
"$VENV_PY" scripts/ramp_harness.py --k8s-participants --namespace matrix-qa "${EXTRA_ARGS[@]}" "$@"
RC=$?
if [ $RC -ne 0 ] && [ "$AUTO_MAX" -eq 1 ] && [ "$MAX_PARTICIPANTS" -gt 1 ] 2>/dev/null; then
  NEXT_MAX=$((MAX_PARTICIPANTS - 1))
  echo "[ramp] Run failed (exit $RC). Retrying with max=$NEXT_MAX." >&2
  "$VENV_PY" scripts/ramp_harness.py --k8s-participants --namespace matrix-qa "${EXTRA_ARGS[@]}" --config config-ramp-qa.yaml --min 1 --max "$NEXT_MAX" --single-pass --skip-tier2
  RC=$?
fi
exit $RC
