#!/usr/bin/env bash
# Dump logs from loadtest participant jobs (e.g. to see why active < jobs).
# Usage: ./scripts/k8s-job-logs.sh [namespace] [max_jobs]
# Example: ./scripts/k8s-job-logs.sh matrix-qa 5
set -e
NAMESPACE="${1:-matrix-qa}"
MAX="${2:-5}"
PREFIX="loadtest-p-"
for i in $(seq 0 $((MAX - 1))); do
  echo "--- job ${PREFIX}${i} ---"
  if ! kubectl logs -n "$NAMESPACE" "job/${PREFIX}${i}" --tail=100 --all-containers=true 2>&1; then
    echo "(no logs or job not found; check: kubectl get jobs -n $NAMESPACE)"
  fi
  echo
done
