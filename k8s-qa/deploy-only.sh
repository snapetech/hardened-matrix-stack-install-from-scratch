#!/usr/bin/env bash
# Deploy the k8s-qa stack and start port-forward (no tests). Use this once, then run
# test subsets in a loop without re-deploying:
#   ./k8s-qa/deploy-only.sh
#   # In another terminal (or after port-forwards are up):
#   MATRIX_QA_TESTS=metrics ./k8s-qa/run-matrix-qa-tests.sh
#   ./k8s-qa/run-quick-tests.sh
#
# Usage: ./k8s-qa/deploy-only.sh
# Optional: MATRIX_BASE_URL=http://node:30048 to skip port-forward and use NodePort.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export KUBECONFIG
NS="matrix-qa"

echo "Deploying k8s-qa (no tests)..."
for f in namespace.yaml postgres.yaml synapse-deployment.yaml nginx-configmap.yaml nginx.yaml coturn.yaml livekit.yaml; do
  [ -f "$SCRIPT_DIR/$f" ] && kubectl apply -f "$SCRIPT_DIR/$f"
done
kubectl rollout restart deployment nginx -n "$NS" 2>/dev/null || true
kubectl rollout restart deployment synapse -n "$NS" 2>/dev/null || true
if kubectl get secret matrix-qa-admin -n "$NS" &>/dev/null; then
  kubectl apply -f "$SCRIPT_DIR/ensure-moderation-bots-configmap.yaml" 2>/dev/null || true
  kubectl apply -f "$SCRIPT_DIR/ensure-moderation-bots-cronjob.yaml" 2>/dev/null || true
  if ! kubectl get secret draupnir-config -n "$NS" &>/dev/null; then
    kubectl delete job moderation-bots-setup -n "$NS" --ignore-not-found 2>/dev/null || true
    kubectl apply -f "$SCRIPT_DIR/moderation-bots-setup-job.yaml" 2>/dev/null || true
    kubectl wait --for=condition=complete job/moderation-bots-setup -n "$NS" --timeout=120s 2>/dev/null || echo "  Moderation bots setup job incomplete (optional)."
  fi
  [ -n "$(kubectl get secret draupnir-config -n "$NS" 2>/dev/null)" ] && kubectl apply -f "$SCRIPT_DIR/draupnir.yaml" -f "$SCRIPT_DIR/mjolnir.yaml" 2>/dev/null || true
fi

echo "Waiting for pods..."
kubectl wait --for=condition=Ready pod -l app=synapse -n "$NS" --timeout=120s 2>/dev/null || true
kubectl wait --for=condition=Ready pod -l app=nginx -n "$NS" --timeout=60s 2>/dev/null || true
kubectl wait --for=condition=Ready pod -l app=postgres -n "$NS" --timeout=60s 2>/dev/null || true
kubectl wait --for=condition=Ready pod -l app=livekit -n "$NS" --timeout=60s 2>/dev/null || true
kubectl wait --for=condition=Ready pod -l app=lk-jwt -n "$NS" --timeout=60s 2>/dev/null || true

echo "Waiting for Synapse to be ready..."
for i in $(seq 1 30); do
  if kubectl get pods -n "$NS" -l app=synapse -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q true; then
    break
  fi
  sleep 5
done

BASE_URL="${MATRIX_BASE_URL:-}"
if [ -z "$BASE_URL" ]; then
  echo "Starting port-forward (nginx 30048, livekit 30049, lk-jwt 30050)..."
  kubectl port-forward -n "$NS" svc/nginx 30048:80 &
  PF1=$!
  kubectl port-forward -n "$NS" svc/livekit 30049:7880 &
  PF2=$!
  kubectl port-forward -n "$NS" svc/lk-jwt 30050:6080 &
  PF3=$!
  trap "kill $PF1 $PF2 $PF3 2>/dev/null" EXIT
  sleep 3
  BASE_URL="http://localhost:30048"
  export MATRIX_BASE_URL="$BASE_URL"
  export LIVEKIT_WS_URL="${LIVEKIT_WS_URL:-ws://localhost:30049}"
  export LIVEKIT_JWT_URL="${LIVEKIT_JWT_URL:-http://localhost:30050}"
fi

echo ""
echo "Deploy done. Base URL: $BASE_URL"
echo "In another terminal, run tests (port-forwards stay up in this shell):"
echo "  export MATRIX_BASE_URL=$BASE_URL"
echo "  MATRIX_QA_TESTS=versions,wellknown_client,metrics  $SCRIPT_DIR/run-matrix-qa-tests.sh"
echo "  MATRIX_QA_TESTS=metrics                           $SCRIPT_DIR/run-matrix-qa-tests.sh"
echo "  $SCRIPT_DIR/run-quick-tests.sh"
echo "  $SCRIPT_DIR/run-matrix-qa-tests.sh   # full suite"
echo ""
echo "Press Ctrl+C to stop port-forwards and exit."
wait
