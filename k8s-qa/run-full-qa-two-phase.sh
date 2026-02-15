#!/usr/bin/env bash
# Run k8s-qa front-to-back: Phase 1 = deploy with NO federation, run all tests (optionals included).
# Phase 2 = enable federation (apply federation nginx config), run federation + blocklist tests.
# Usage:
#   ./k8s-qa/run-full-qa-two-phase.sh
#   MATRIX_BASE_URL=http://node:30048 ./k8s-qa/run-full-qa-two-phase.sh  # use NodePort, no port-forward
#
# Ensures matrix-qa-admin Secret exists (creates with qa-admin-password) so moderation bots and tests run.
# Optional: create Secret msmtp-credentials for email test; leave absent to skip.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export KUBECONFIG
NS="matrix-qa"
FAILED=0

echo "=============================================="
echo " k8s-qa two-phase: no-federation first, then federation + blocklists"
echo "=============================================="

# Ensure namespace exists (so we can create Secret before deploy)
kubectl apply -f "$SCRIPT_DIR/namespace.yaml" 2>/dev/null || true

# Ensure matrix-qa-admin Secret exists so moderation bots deploy and tests run
if ! kubectl get secret matrix-qa-admin -n "$NS" &>/dev/null; then
  echo "Creating matrix-qa-admin Secret (admin-password=qa-admin-password) so moderation bots run..."
  kubectl create secret generic matrix-qa-admin -n "$NS" --from-literal=admin-password=qa-admin-password
fi

# ---------- Phase 1: Deploy with NO federation, run all tests ----------
echo ""
echo "========== Phase 1: First install — no federation =========="
echo "Deploying with default nginx (federation blocked, .well-known/server 404)..."
export FEDERATION_ENABLED=0
"$SCRIPT_DIR/deploy-and-test.sh"
P1_EXIT=$?
if [ "$P1_EXIT" -ne 0 ]; then
  echo "Phase 1 failed (exit $P1_EXIT). Fix before Phase 2."
  exit "$P1_EXIT"
fi

# deploy-and-test.sh exits and kills port-forward. So we need to start port-forward again for Phase 2
# unless MATRIX_BASE_URL is set (user provided NodePort URL).
BASE_URL="${MATRIX_BASE_URL:-}"
BASE_URL="${BASE_URL%/}"
if [ -z "$BASE_URL" ]; then
  echo ""
  echo "Starting port-forward for Phase 2..."
  kubectl port-forward -n "$NS" svc/nginx 30048:80 &
  PF_PID=$!
  trap "kill $PF_PID 2>/dev/null" EXIT
  sleep 3
  BASE_URL="http://localhost:30048"
  export MATRIX_BASE_URL="$BASE_URL"
  export LIVEKIT_WS_URL="${LIVEKIT_WS_URL:-ws://localhost:30049}"
  export LIVEKIT_JWT_URL="${LIVEKIT_JWT_URL:-http://localhost:30050}"
  kubectl port-forward -n "$NS" svc/livekit 30049:7880 &
  kubectl port-forward -n "$NS" svc/lk-jwt 30050:6080 &
  sleep 2
else
  # NodePort: infer LiveKit URLs from same host if not set (so Phase 2 call tests can run)
  if [ -z "${LIVEKIT_WS_URL:-}" ] || [ -z "${LIVEKIT_JWT_URL:-}" ]; then
    BASE_HOST=$(echo "$BASE_URL" | sed -n 's|^[^:]*://\([^:/]*\).*|\1|p')
    [ -z "$BASE_HOST" ] && BASE_HOST="localhost"
    [ -z "${LIVEKIT_WS_URL:-}" ] && export LIVEKIT_WS_URL="ws://${BASE_HOST}:30049"
    [ -z "${LIVEKIT_JWT_URL:-}" ] && export LIVEKIT_JWT_URL="http://${BASE_HOST}:30050"
  fi
fi

# ---------- Phase 2: Enable federation, run federation + blocklist tests ----------
echo ""
echo "========== Phase 2: Enable federation and test blocklists =========="
echo "Applying nginx-configmap-federation.yaml (allow federation, serve .well-known/matrix/server)..."
kubectl apply -f "$SCRIPT_DIR/nginx-configmap-federation.yaml"
kubectl rollout restart deployment nginx -n "$NS"
kubectl rollout status deployment nginx -n "$NS" --timeout=90s

echo "Running tests with FEDERATION_ENABLED=1 (federation allowed + subscribe to community list)..."
cd "$REPO_ROOT"
if kubectl get secret matrix-qa-admin -n "$NS" &>/dev/null && kubectl get secret draupnir-config -n "$NS" &>/dev/null; then
  export MATRIX_QA_ADMIN_PASSWORD=$(kubectl get secret matrix-qa-admin -n "$NS" -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null)
  export MATRIX_QA_DRAUPNIR_MANAGEMENT_ROOM=$(kubectl get secret draupnir-config -n "$NS" -o jsonpath='{.data.management_room}' 2>/dev/null | base64 -d 2>/dev/null)
  export MODERATION_BOTS_TEST=1
fi
export FEDERATION_ENABLED=1
if "$SCRIPT_DIR/run-matrix-qa-tests.sh" "$BASE_URL"; then
  echo "  Phase 2 API + federation + blocklist tests passed."
else
  echo "  Phase 2 FAILED."
  FAILED=$((FAILED + 1))
fi

echo ""
echo "=============================================="
if [ "$FAILED" -eq 0 ]; then
  echo " All two-phase QA passed (Phase 1: no-federation, Phase 2: federation + blocklists)."
  exit 0
else
  echo " Failed: $FAILED phase(s)."
  exit 1
fi
