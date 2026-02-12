#!/bin/bash
# Apply footgun fixes on an already-running Matrix host.
# Run with (password must end with newline for sudo -S):
#   (secret-tool lookup service sudo-remote user "lukano@timeways.net"; echo; cat apply-footgun-fixes-remote.sh) | ssh lukano@timeways.net 'sudo -S -p "" bash -s'
# With files in lukano's home: (secret-tool ...; echo; echo 'REPO_DIR=/home/lukano'; cat apply-footgun-fixes-remote.sh) | ssh ...
# Or run on host: sudo REPO_DIR=/path/to/repo bash apply-footgun-fixes-remote.sh
set -e
REPO_DIR="${REPO_DIR:-$HOME}"
[ -f "$REPO_DIR/docker-compose.yml" ] && EC_SOURCE="$REPO_DIR/docker-compose.yml" || EC_SOURCE="$REPO_DIR/element-call/docker-compose.yml"

echo "[1] Copy updated backup script and element-call docker-compose..."
cp -a "$REPO_DIR/backup-matrix.sh" /opt/matrix-backup/backup-matrix.sh 2>/dev/null && chmod +x /opt/matrix-backup/backup-matrix.sh && echo "  backup-matrix.sh updated" || echo "  (no backup-matrix.sh in $REPO_DIR)"
if [ -f "$EC_SOURCE" ]; then
  cp -a "$EC_SOURCE" /opt/element-call/docker-compose.yml
  echo "  docker-compose.yml updated"
fi

echo "[2] Federation: remove no-federation if federation is enabled..."
if grep -q "federation" /etc/matrix-synapse/conf.d/listener.yaml 2>/dev/null; then
  rm -f /etc/matrix-synapse/conf.d/44-no-federation.yaml
  echo "  Federation enabled: removed 44-no-federation.yaml"
else
  echo "  Federation disabled: leaving 44-no-federation.yaml as-is"
fi

echo "[3] Nginx: add metrics-grafana and element-call includes if missing (match listen 443 ssl http2;)..."
MATRIX_VHOST="/etc/nginx/sites-available/matrix"
if ! grep -q "metrics-grafana.conf" "$MATRIX_VHOST" 2>/dev/null; then
  if [ -f /etc/nginx/snippets/metrics-grafana.conf ]; then
    sed -i '/listen 443 ssl http2;/a\    include /etc/nginx/snippets/metrics-grafana.conf;' "$MATRIX_VHOST"
    echo "  Added metrics-grafana include"
  fi
fi
if ! grep -q "element-call-livekit.conf" "$MATRIX_VHOST" 2>/dev/null; then
  if [ -f /etc/nginx/snippets/element-call-livekit.conf ]; then
    sed -i '/listen 443 ssl http2;/a\    include /etc/nginx/snippets/element-call-livekit.conf;' "$MATRIX_VHOST"
    echo "  Added element-call-livekit include"
  fi
fi

echo "[4] Element Call nginx snippet: add 301 redirects for no-trailing-slash..."
LIVEKIT_SNIPPET="/etc/nginx/snippets/element-call-livekit.conf"
if [ -f "$LIVEKIT_SNIPPET" ] && ! grep -q "location = /livekit/jwt " "$LIVEKIT_SNIPPET" 2>/dev/null; then
  REDIRECTS="# Redirect no-trailing-slash to slash
location = /livekit/jwt { return 301 /livekit/jwt/; }
location = /livekit/sfu { return 301 /livekit/sfu/; }
"
  echo "$REDIRECTS$(cat "$LIVEKIT_SNIPPET")" > "$LIVEKIT_SNIPPET"
  echo "  Added 301 redirects to livekit snippet"
else
  echo "  Livekit snippet already has redirects or missing"
fi

echo "[5] Grafana: remove anonymous.ini if metrics-auth not in use..."
if ! grep -q "metrics-auth/validate" "$MATRIX_VHOST" 2>/dev/null; then
  rm -f /etc/grafana/conf.d/anonymous.ini
  echo "  Removed Grafana anonymous (no metrics gating)"
else
  echo "  Metrics-auth in use: keeping Grafana anonymous"
fi

echo "[6] Prometheus: ensure bound to localhost and restart..."
if [ -f /etc/default/prometheus ] && grep -q "web.listen-address" /etc/default/prometheus 2>/dev/null; then
  systemctl restart prometheus 2>/dev/null || true
  echo "  Prometheus restarted"
fi

echo "[7] Nginx test and reload..."
nginx -t && systemctl reload nginx
echo "  Nginx reloaded"

echo "[8] Element Call: restart Docker stack with new port bindings..."
if [ -d /opt/element-call ]; then
  (cd /opt/element-call && (docker compose down 2>/dev/null || docker-compose down 2>/dev/null) || true)
  (cd /opt/element-call && (docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null) || true)
  echo "  Element Call containers restarted"
fi

echo "[9] Synapse: restart if we removed federation file..."
if [ -f /etc/matrix-synapse/conf.d/44-no-federation.yaml ]; then
  echo "  (no synapse restart needed)"
else
  systemctl restart matrix-synapse 2>/dev/null || true
  echo "  Synapse restarted (federation config changed)"
fi

echo "Done. Test: curl -sI https://matrix.timeways.net/_matrix/client/versions && curl -sI https://matrix.timeways.net/metrics/"
