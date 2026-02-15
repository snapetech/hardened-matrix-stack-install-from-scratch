#!/usr/bin/env bash
# Optional: send one test email from the cluster to verify the msmtp/alert path (same path fail2ban uses on VM).
# Requires Secret msmtp-credentials (password + alert_email). Never commit the secret or app password.
#
# Create the secret once (do not commit):
#   kubectl create secret generic msmtp-credentials -n matrix-qa \
#     --from-literal=password=YOUR_GMAIL_APP_PASSWORD \
#     --from-literal=alert_email=your@gmail.com
#
# Run: ./k8s-qa/send-test-email.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export KUBECONFIG

if ! kubectl get secret msmtp-credentials -n matrix-qa &>/dev/null; then
  echo "Secret msmtp-credentials not found in matrix-qa. Create it first (see script header or README)."
  exit 1
fi

kubectl apply -f "$SCRIPT_DIR/send-test-email-configmap.yaml"
kubectl delete job send-test-email -n matrix-qa --ignore-not-found
kubectl apply -f "$SCRIPT_DIR/send-test-email-job.yaml"

echo "Waiting for send-test-email job to complete..."
kubectl wait --for=condition=complete job/send-test-email -n matrix-qa --timeout=60s
kubectl logs job/send-test-email -n matrix-qa
echo "Check your inbox for the test email."
