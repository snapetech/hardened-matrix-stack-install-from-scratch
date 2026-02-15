#!/usr/bin/env bash
# Deploy full k8s-qa stack (namespace, Postgres, Synapse, LiveKit, lk-jwt), wait for Ready, then run E2E tests.
# Usage:
#   ./k8s-qa/deploy-and-test.sh [BASE_URL]
#   MATRIX_BASE_URL=http://node-ip:30048 ./k8s-qa/deploy-and-test.sh
#
# If BASE_URL is not set, after deploy we use port-forward and localhost. Requires kubectl, curl, jq.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export KUBECONFIG

echo "Deploying k8s-qa (namespace, postgres, synapse, nginx, coturn, livekit)..."
for f in namespace.yaml postgres.yaml synapse-deployment.yaml nginx-configmap.yaml nginx.yaml coturn.yaml livekit.yaml; do
  [ -f "$SCRIPT_DIR/$f" ] && kubectl apply -f "$SCRIPT_DIR/$f"
done
# Optional: moderation bots (Draupnir + Mjolnir). Requires Secret matrix-qa-admin with key admin-password.
if kubectl get secret matrix-qa-admin -n matrix-qa &>/dev/null; then
  kubectl apply -f "$SCRIPT_DIR/ensure-moderation-bots-configmap.yaml" 2>/dev/null || true
  kubectl apply -f "$SCRIPT_DIR/ensure-moderation-bots-cronjob.yaml" 2>/dev/null || true
  if ! kubectl get secret draupnir-config -n matrix-qa &>/dev/null; then
    echo "Running moderation-bots-setup Job (one-time)..."
    kubectl delete job moderation-bots-setup -n matrix-qa --ignore-not-found 2>/dev/null || true
    kubectl apply -f "$SCRIPT_DIR/moderation-bots-setup-job.yaml" 2>/dev/null || true
    if kubectl wait --for=condition=complete job/moderation-bots-setup -n matrix-qa --timeout=120s 2>/dev/null; then
      "$SCRIPT_DIR/create-moderation-secrets-from-job.sh" 2>/dev/null || true
    fi
  fi
  if kubectl get secret draupnir-config -n matrix-qa &>/dev/null; then
    kubectl apply -f "$SCRIPT_DIR/draupnir.yaml" -f "$SCRIPT_DIR/mjolnir.yaml" 2>/dev/null || true
  fi
fi
# Optional email test (ConfigMap + Job) is applied only when running send-test-email.sh

echo "Waiting for pods in matrix-qa..."
kubectl wait --for=condition=Ready pod -l app=synapse -n matrix-qa --timeout=120s 2>/dev/null || true
kubectl wait --for=condition=Ready pod -l app=nginx -n matrix-qa --timeout=60s 2>/dev/null || true
kubectl wait --for=condition=Ready pod -l app=postgres -n matrix-qa --timeout=60s 2>/dev/null || true
kubectl wait --for=condition=Ready pod -l app=coturn -n matrix-qa --timeout=60s 2>/dev/null || true
kubectl wait --for=condition=Ready pod -l app=livekit -n matrix-qa --timeout=60s 2>/dev/null || true
kubectl wait --for=condition=Ready pod -l app=lk-jwt -n matrix-qa --timeout=60s 2>/dev/null || true
# Optional: verify Coturn port from inside cluster (non-fatal)
if kubectl get deployment coturn -n matrix-qa &>/dev/null && [ -f "$SCRIPT_DIR/coturn-test-job.yaml" ]; then
  kubectl delete job coturn-test -n matrix-qa --ignore-not-found 2>/dev/null || true
  kubectl apply -f "$SCRIPT_DIR/coturn-test-job.yaml" 2>/dev/null && \
    kubectl wait --for=condition=complete job/coturn-test -n matrix-qa --timeout=30s 2>/dev/null || \
    echo "  Coturn test job failed or skipped."
fi

# Synapse may take longer (init: generate + postgres)
echo "Waiting for Synapse to be ready..."
for i in $(seq 1 30); do
  if kubectl get pods -n matrix-qa -l app=synapse -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running; then
    if kubectl get pods -n matrix-qa -l app=synapse -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q true; then
      break
    fi
  fi
  sleep 5
done

BASE_URL="${MATRIX_BASE_URL:-}"
LIVEKIT_WS_URL="${LIVEKIT_WS_URL:-}"
LIVEKIT_JWT_URL="${LIVEKIT_JWT_URL:-}"

if [ -z "$BASE_URL" ]; then
  echo "No MATRIX_BASE_URL set; starting port-forward (nginx 30048, LiveKit 30049, lk-jwt 30050)..."
  kubectl port-forward -n matrix-qa svc/nginx 30048:80 &
  PF1=$!
  kubectl port-forward -n matrix-qa svc/livekit 30049:7880 &
  PF2=$!
  kubectl port-forward -n matrix-qa svc/lk-jwt 30050:6080 &
  PF3=$!
  trap "kill $PF1 $PF2 $PF3 2>/dev/null" EXIT
  sleep 3
  BASE_URL="http://localhost:30048"
  LIVEKIT_WS_URL="ws://localhost:30049"
  LIVEKIT_JWT_URL="http://localhost:30050"
fi

echo "Running E2E QA..."
cd "$REPO_ROOT"
# When moderation bots are deployed, run moderation-bots test (admin password + Draupnir management room from Secrets)
if kubectl get secret matrix-qa-admin -n matrix-qa &>/dev/null && kubectl get secret draupnir-config -n matrix-qa &>/dev/null; then
  MATRIX_QA_ADMIN_PASSWORD=$(kubectl get secret matrix-qa-admin -n matrix-qa -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null)
  MATRIX_QA_DRAUPNIR_MANAGEMENT_ROOM=$(kubectl get secret draupnir-config -n matrix-qa -o jsonpath='{.data.management_room}' 2>/dev/null | base64 -d 2>/dev/null)
  export MATRIX_QA_ADMIN_PASSWORD
  export MATRIX_QA_DRAUPNIR_MANAGEMENT_ROOM
  export MODERATION_BOTS_TEST=1
fi
MATRIX_BASE_URL="$BASE_URL" LIVEKIT_WS_URL="$LIVEKIT_WS_URL" LIVEKIT_JWT_URL="$LIVEKIT_JWT_URL" "$SCRIPT_DIR/run-e2e-qa.sh"

# Optional: if msmtp credentials secret exists, send one test email (same path fail2ban/msmtp use on VM)
if kubectl get secret msmtp-credentials -n matrix-qa &>/dev/null; then
  echo ""
  echo "Optional: sending test email (msmtp/alert path)..."
  "$SCRIPT_DIR/send-test-email.sh" || echo "  Email test failed or skipped."
fi
