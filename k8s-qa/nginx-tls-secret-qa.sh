#!/usr/bin/env bash
# Create self-signed TLS cert for nginx federation port 8448 (qa.local).
# lk-jwt validates OpenID via matrix://qa.local which resolves to https://qa.local:8448; this cert allows that.
# Run once: ./nginx-tls-secret-qa.sh
# Requires: openssl, kubectl. Uses LIVEKIT_INSECURE_SKIP_VERIFY_TLS in lk-jwt to accept this cert.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NAMESPACE:-matrix-qa}"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout "$DIR/tls.key" -out "$DIR/tls.crt" \
  -subj "/CN=qa.local" \
  -addext "subjectAltName=DNS:qa.local,DNS:nginx.$NS.svc,DNS:nginx.$NS.svc.cluster.local,IP:10.43.101.44"
kubectl create secret tls nginx-tls-qa --cert="$DIR/tls.crt" --key="$DIR/tls.key" -n "$NS" --dry-run=client -o yaml | kubectl apply -f - -n "$NS"
echo "Secret nginx-tls-qa applied in $NS. Restart nginx if already running: kubectl rollout restart deployment/nginx -n $NS"
