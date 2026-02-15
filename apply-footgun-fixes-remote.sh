#!/bin/bash
# Apply footgun fixes on an already-running Matrix host.
#
# Run once (do not retry on failure; fix cause first to avoid fail2ban):
#   ./run-remote-sudo.sh lukano@timeways.net apply-footgun-fixes-remote.sh
# Or with REPO_DIR set on remote: (echo 'REPO_DIR=/home/lukano'; cat apply-footgun-fixes-remote.sh) | ./run-remote-sudo.sh lukano@timeways.net
#
# Or on the host: sudo REPO_DIR=/path/to/repo bash apply-footgun-fixes-remote.sh
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

echo "[3] Nginx: add metrics-netdata and element-call includes if missing (match listen 443 ssl http2;)..."
MATRIX_VHOST="/etc/nginx/sites-available/matrix"
if ! grep -q "metrics-netdata.conf" "$MATRIX_VHOST" 2>/dev/null; then
  if [ -f /etc/nginx/snippets/metrics-netdata.conf ]; then
    sed -i '/listen 443 ssl http2;/a\    include /etc/nginx/snippets/metrics-netdata.conf;' "$MATRIX_VHOST"
    echo "  Added metrics-netdata include"
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

echo "[5] Netdata: ensure bound to localhost and restart if metrics-auth in use..."
if grep -q "metrics-auth/validate" "$MATRIX_VHOST" 2>/dev/null && [ -d /etc/netdata ]; then
  if [ -d /etc/netdata/netdata.conf.d ] && [ ! -f /etc/netdata/netdata.conf.d/bind-localhost.conf ]; then
    printf '[web]\n    bind socket to IP = 127.0.0.1\n' > /etc/netdata/netdata.conf.d/bind-localhost.conf
    echo "  Netdata: added bind to 127.0.0.1"
  fi
  systemctl restart netdata 2>/dev/null || true
  echo "  Netdata restarted"
fi

echo "[6] Nginx test and reload..."
nginx -t && systemctl reload nginx
echo "  Nginx reloaded"

echo "[7] Element Call: restart Docker stack with new port bindings..."
if [ -d /opt/element-call ]; then
  (cd /opt/element-call && (docker compose down 2>/dev/null || docker-compose down 2>/dev/null) || true)
  (cd /opt/element-call && (docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null) || true)
  echo "  Element Call containers restarted"
fi

echo "[8] Synapse: restart if we removed federation file..."
if [ -f /etc/matrix-synapse/conf.d/44-no-federation.yaml ]; then
  echo "  (no synapse restart needed)"
else
  systemctl restart matrix-synapse 2>/dev/null || true
  echo "  Synapse restarted (federation config changed)"
fi

echo "Done. Test: curl -sI https://matrix.timeways.net/_matrix/client/versions && curl -sI https://matrix.timeways.net/metrics/"
