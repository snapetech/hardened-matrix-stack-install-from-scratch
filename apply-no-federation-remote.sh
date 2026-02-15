#!/bin/bash
# On an existing server: ensure federation is blocked at nginx and Synapse, then validate.
# Run: ./run-remote-sudo.sh user@host apply-no-federation-remote.sh
# Or with repo on server: sudo bash apply-no-federation-remote.sh
# Requires: REPO_DIR or script run from repo root so nginx-no-federation.conf and validate-no-federation.sh are found.
set -e
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")" && pwd)}"
MATRIX_VHOST="/etc/nginx/sites-available/matrix"

echo "[1] Synapse: ensure federation whitelist empty and listener client-only..."
if [ -f "$REPO_DIR/synapse-no-federation.yaml" ]; then
  mkdir -p /etc/matrix-synapse/conf.d
  cp "$REPO_DIR/synapse-no-federation.yaml" /etc/matrix-synapse/conf.d/44-no-federation.yaml
  echo "  Installed 44-no-federation.yaml"
fi
if [ -f /etc/matrix-synapse/conf.d/listener.yaml ]; then
  if grep -q "federation" /etc/matrix-synapse/conf.d/listener.yaml; then
    echo "  WARNING: listener.yaml still has 'federation' in resources. Edit to names: [client] only and restart Synapse."
  else
    echo "  Listener has no federation resource."
  fi
fi

echo "[2] Nginx: block /_matrix/federation and /.well-known/matrix/server..."
mkdir -p /etc/nginx/snippets
if [ -f "$REPO_DIR/nginx-no-federation.conf" ]; then
  cp "$REPO_DIR/nginx-no-federation.conf" /etc/nginx/snippets/no-federation.conf
else
  # Embedded so script works when piped to remote without repo
  cat > /etc/nginx/snippets/no-federation.conf << 'NGINX_SNIP'
# Block federation at the proxy when federation is disabled.
location /_matrix/federation {
    return 403;
}
location = /.well-known/matrix/server {
    return 404;
}
NGINX_SNIP
fi
if ! grep -q "no-federation.conf" "${MATRIX_VHOST}" 2>/dev/null; then
  sed -i '/location \/_matrix {/i\    include /etc/nginx/snippets/no-federation.conf;' "${MATRIX_VHOST}"
  echo "  Added no-federation include to matrix vhost."
else
  echo "  no-federation already included."
fi
nginx -t && systemctl reload nginx 2>/dev/null || true

echo "[3] Run validation..."
if [ -x "$REPO_DIR/validate-no-federation.sh" ]; then
  "$REPO_DIR/validate-no-federation.sh" || true
else
  echo "  validate-no-federation.sh not found or not executable."
fi

echo "Done. Federation surface should be closed; run validate-no-federation.sh to confirm."
