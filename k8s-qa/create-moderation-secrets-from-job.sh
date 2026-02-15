#!/usr/bin/env bash
# After moderation-bots-setup Job completes, parse its log and create Secrets draupnir-config, mjolnir-config.
# Usage: ./k8s-qa/create-moderation-secrets-from-job.sh
# Requires: kubectl, Job moderation-bots-setup completed in namespace matrix-qa.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${MATRIX_QA_NS:-matrix-qa}"
JOB="${MODERATION_BOTS_JOB:-moderation-bots-setup}"

pod=$(kubectl get pods -n "$NS" -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$pod" ]; then
  echo "No pod found for job $JOB in $NS. Run the Job first."
  exit 1
fi
log=$(kubectl logs -n "$NS" "$pod" 2>/dev/null)
eval "$(echo "$log" | grep -E '^(DRAUPNIR_ACCESS_TOKEN|DRAUPNIR_MANAGEMENT_ROOM|MJOLNIR_ACCESS_TOKEN|MJOLNIR_MANAGEMENT_ROOM)=')"
for v in DRAUPNIR_ACCESS_TOKEN DRAUPNIR_MANAGEMENT_ROOM MJOLNIR_ACCESS_TOKEN MJOLNIR_MANAGEMENT_ROOM; do
  [ -z "${!v}" ] && echo "Missing $v in job log" && exit 1
done

kubectl create secret generic draupnir-config -n "$NS" \
  --from-literal=access_token="$DRAUPNIR_ACCESS_TOKEN" \
  --from-literal=management_room="$DRAUPNIR_MANAGEMENT_ROOM" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic mjolnir-config -n "$NS" \
  --from-literal=access_token="$MJOLNIR_ACCESS_TOKEN" \
  --from-literal=management_room="$MJOLNIR_MANAGEMENT_ROOM" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Secrets draupnir-config and mjolnir-config updated in $NS."
