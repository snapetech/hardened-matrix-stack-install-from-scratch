#!/usr/bin/env bash
# Run ramp 1→10 with Synapse at 1c/1g, then at 4c/4g. Saves results per config for comparison.
# Prereqs: KUBECONFIG (or ~/.kube/config), test_users.json + test_room_id.txt, SSH to k8s node for load.
# Usage: ./run-ramp-1-10-both-synapse-configs.sh
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_QA_DIR="${K8S_QA_DIR:-$SCRIPT_DIR/../k8s-qa}"
NS="${LOADTEST_K8S_NAMESPACE:-matrix-qa}"
RESULTS="$SCRIPT_DIR/results"
mkdir -p "$RESULTS/ramp_1c1g" "$RESULTS/ramp_4c4g"

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "kubectl cannot reach cluster. Set KUBECONFIG." >&2
  exit 1
fi

# Fail fast if node has disk pressure (pods will be evicted and ramp will fail).
if kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="DiskPressure")].status}' 2>/dev/null | grep -q True; then
  echo "ERROR: At least one node has DiskPressure. Pods will be evicted and the ramp will fail." >&2
  echo "  On the k3s node: free disk so >10% is free (e.g. sudo pacman -Sc, or prune Docker/k3s images)." >&2
  echo "  Or relax eviction: add to /etc/rancher/k3s/config.yaml:" >&2
  echo '    kubelet-arg:' >&2
  echo '    - "eviction-hard=memory.available<100Mi,nodefs.available<3%,nodefs.inodesFree<5%,imagefs.available<15%"' >&2
  echo "  then: sudo systemctl restart k3s" >&2
  exit 1
fi

echo "=== Synapse 1c/1g: apply and rollout ===" >&2
kubectl apply -f "$K8S_QA_DIR/synapse-deployment.yaml" -n "$NS" 2>&1
kubectl rollout status deployment/synapse -n "$NS" --timeout=180s 2>&1

echo "" >&2
echo "=== Ramp 1→10 with Synapse 1c/1g ===" >&2
RAMP_LOG="$RESULTS/ramp_1c1g/ramp.log"
./run-ramp-k8s.sh --config config-ramp-qa.yaml --min 1 --max 10 --single-pass --skip-tier2 2>&1 | tee "$RAMP_LOG"
RC1=${PIPESTATUS[0]}
cp -f "$RESULTS/load_ramp.jsonl" "$RESULTS/ramp_1c1g/load_ramp.jsonl" 2>/dev/null || true
cp -f "$RESULTS/ramp_metrics_summary.json" "$RESULTS/ramp_1c1g/ramp_metrics_summary.json" 2>/dev/null || true
echo "[saved] $RESULTS/ramp_1c1g/load_ramp.jsonl and ramp_metrics_summary.json" >&2

echo "" >&2
echo "=== Synapse 4c/4g: apply and rollout ===" >&2
kubectl apply -f "$K8S_QA_DIR/synapse-deployment-4c4g.yaml" -n "$NS" 2>&1
kubectl rollout status deployment/synapse -n "$NS" --timeout=180s 2>&1

echo "" >&2
echo "=== Ramp 1→10 with Synapse 4c/4g ===" >&2
RAMP_LOG="$RESULTS/ramp_4c4g/ramp.log"
./run-ramp-k8s.sh --config config-ramp-qa.yaml --min 1 --max 10 --single-pass --skip-tier2 2>&1 | tee "$RAMP_LOG"
RC2=${PIPESTATUS[0]}
cp -f "$RESULTS/load_ramp.jsonl" "$RESULTS/ramp_4c4g/load_ramp.jsonl" 2>/dev/null || true
cp -f "$RESULTS/ramp_metrics_summary.json" "$RESULTS/ramp_4c4g/ramp_metrics_summary.json" 2>/dev/null || true
echo "[saved] $RESULTS/ramp_4c4g/load_ramp.jsonl and ramp_metrics_summary.json" >&2

echo "" >&2
echo "=== Done. Compare server (stack) load: ===" >&2
echo "  1c/1g: $RESULTS/ramp_1c1g/load_ramp.jsonl  (stack_cpu_m, stack_mem_mi by n)" >&2
echo "  4c/4g: $RESULTS/ramp_4c4g/load_ramp.jsonl  (stack_cpu_m, stack_mem_mi by n)" >&2
echo "  Summary: ramp_1c1g/ramp_metrics_summary.json vs ramp_4c4g/ramp_metrics_summary.json" >&2
if [ "$RC1" -ne 0 ] || [ "$RC2" -ne 0 ]; then
  echo "Exit: 1c/1g=$RC1 4c/4g=$RC2" >&2
  exit 1
fi
exit 0
