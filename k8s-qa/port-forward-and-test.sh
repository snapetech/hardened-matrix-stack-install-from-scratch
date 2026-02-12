#!/usr/bin/env bash
# Port-forward Synapse to localhost:30048, run QA tests, then stop the forward.
# Use when you're not on the cluster node (e.g. from a machine with kubectl and KUBECONFIG).
# Usage: ./k8s-qa/port-forward-and-test.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export KUBECONFIG

if ! kubectl get ns matrix-qa &>/dev/null; then
  echo "Namespace matrix-qa not found. Deploy first: kubectl apply -f k8s-qa/"
  exit 1
fi

kubectl port-forward -n matrix-qa svc/synapse 30048:8008 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null' EXIT
sleep 2
"$SCRIPT_DIR/run-matrix-qa-tests.sh" "http://localhost:30048"
