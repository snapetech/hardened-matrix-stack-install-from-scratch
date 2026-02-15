#!/usr/bin/env bash
# Fix 502 on metrics login: use Synapse on localhost and (optional) deploy updated proxy script.
# Run on remote with sudo, e.g.:
#   ./run-remote-sudo.sh lukano@timeways.net fix-metrics-auth-502-remote.sh
# With repo files: (echo 'REPO_DIR=/path/to/repo'; cat fix-metrics-auth-502-remote.sh) | ./run-remote-sudo.sh lukano@timeways.net
set -e
REPO_DIR="${REPO_DIR:-$HOME}"

echo "[1] Ensure metrics-auth proxy uses Synapse on localhost (fix 502)..."
mkdir -p /opt/metrics-auth
# Update or create service so SYNAPSE_INTERNAL_URL is set (proxy talks to 127.0.0.1:8008, no SSL)
if [ -f /etc/systemd/system/metrics-auth-proxy.service ]; then
  if ! grep -q "SYNAPSE_INTERNAL_URL" /etc/systemd/system/metrics-auth-proxy.service; then
    sed -i '/\[Service\]/a Environment=SYNAPSE_INTERNAL_URL=http://127.0.0.1:8008' /etc/systemd/system/metrics-auth-proxy.service
    echo "  Added SYNAPSE_INTERNAL_URL to service."
  else
    echo "  SYNAPSE_INTERNAL_URL already set."
  fi
else
  echo "  No metrics-auth-proxy.service found; install from repo (setup or migrate script)."
fi

echo "[2] Deploy updated proxy script (supports SYNAPSE_INTERNAL_URL)..."
if [ -f "$REPO_DIR/metrics-auth-proxy.py" ]; then
  cp "$REPO_DIR/metrics-auth-proxy.py" /opt/metrics-auth/ && chmod 755 /opt/metrics-auth/metrics-auth-proxy.py
  echo "  Updated metrics-auth-proxy.py."
else
  echo "  (No $REPO_DIR/metrics-auth-proxy.py; skip deploy.)"
fi

echo "[3] Restart metrics-auth-proxy..."
systemctl daemon-reload
systemctl restart metrics-auth-proxy
echo "  Restarted."

echo "[4] Quick check: proxy and Synapse..."
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:9091/metrics-auth/ && echo " metrics-auth (expect 200)" || echo " metrics-auth failed"
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8008/health && echo " Synapse (expect 200)" || echo " Synapse failed"
echo "Done. Try https://matrix.timeways.net/metrics/ again (log in with Matrix)."
