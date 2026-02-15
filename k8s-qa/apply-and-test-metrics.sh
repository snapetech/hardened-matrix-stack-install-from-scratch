#!/usr/bin/env bash
# Apply Synapse + nginx config (metrics on main listener) and restart, then run quick tests.
# Run from repo root after deploy-only.sh is running in another terminal (or use MATRIX_BASE_URL if already port-forwarding).
# Usage: ./k8s-qa/apply-and-test-metrics.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export KUBECONFIG

kubectl apply -f "$SCRIPT_DIR/synapse-deployment.yaml" -f "$SCRIPT_DIR/nginx-configmap.yaml"
kubectl rollout restart deployment synapse deployment nginx -n matrix-qa
kubectl rollout status deployment synapse -n matrix-qa --timeout=120s
kubectl rollout status deployment nginx -n matrix-qa --timeout=60s

echo ""
echo "Running quick tests (versions, federation_blocked, wellknown_client, metrics)..."
BASE_URL="${MATRIX_BASE_URL:-http://localhost:30048}"
export MATRIX_BASE_URL="$BASE_URL"
"$SCRIPT_DIR/run-quick-tests.sh"
