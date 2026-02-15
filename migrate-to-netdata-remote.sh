#!/usr/bin/env bash
# Remove Prometheus + Grafana from the remote, install Netdata, and gate it behind Synapse (metrics-auth).
# Run on remote with sudo, e.g.:
#   ./run-remote-sudo.sh lukano@timeways.net migrate-to-netdata-remote.sh
# Or with MATRIX_DOMAIN set: (echo 'MATRIX_DOMAIN=matrix.timeways.net'; cat migrate-to-netdata-remote.sh) | ./run-remote-sudo.sh lukano@timeways.net
set -e

MATRIX_DOMAIN="${MATRIX_DOMAIN:-}"
MATRIX_VHOST="/etc/nginx/sites-available/matrix"
if [ -z "$MATRIX_DOMAIN" ] && [ -f "$MATRIX_VHOST" ]; then
  MATRIX_DOMAIN=$(grep -m1 "server_name" "$MATRIX_VHOST" | sed -n 's/.*server_name[^a-zA-Z0-9.]*\([a-zA-Z0-9.-]*\).*/\1/p' | tr -d ';')
fi
MATRIX_DOMAIN="${MATRIX_DOMAIN:-matrix.timeways.net}"

echo "[1] Stop and disable Prometheus, node-exporter, Grafana..."
systemctl stop prometheus prometheus-node-exporter grafana-server 2>/dev/null || true
systemctl disable prometheus prometheus-node-exporter grafana-server 2>/dev/null || true
echo "  Stopped and disabled."

echo "[2] Remove nginx include for metrics-grafana.conf..."
if grep -q "metrics-grafana.conf" "$MATRIX_VHOST" 2>/dev/null; then
  sed -i '\|include /etc/nginx/snippets/metrics-grafana.conf|d' "$MATRIX_VHOST"
  echo "  Removed metrics-grafana include."
else
  echo "  (no metrics-grafana include found)"
fi

echo "[3] Install Netdata (kickstart, non-interactive)..."
if ! command -v netdata &>/dev/null; then
  curl -sS https://get.netdata.cloud/kickstart.sh -o /tmp/netdata-kickstart.sh
  sh /tmp/netdata-kickstart.sh --dont-wait --disable-telemetry
  echo "  Netdata installed."
else
  echo "  Netdata already installed."
fi

echo "[4] Bind Netdata to 127.0.0.1..."
mkdir -p /etc/netdata/netdata.conf.d
cat > /etc/netdata/netdata.conf.d/bind-localhost.conf << 'NETDATA_BIND'
[web]
    bind socket to IP = 127.0.0.1
NETDATA_BIND
systemctl restart netdata 2>/dev/null || true
systemctl enable netdata 2>/dev/null || true
echo "  Netdata bound to localhost."

echo "[5] Create nginx snippet metrics-netdata.conf and add to matrix vhost..."
mkdir -p /etc/nginx/snippets
cat > /etc/nginx/snippets/metrics-netdata.conf << SNIPPET
# Gated Netdata (auth_request via metrics-auth-proxy). No Netdata login required when gated.
location = /metrics-auth/validate {
    internal;
    proxy_pass http://127.0.0.1:9091/metrics-auth/validate;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header Cookie \$http_cookie;
}
location /metrics-auth/ {
    proxy_pass http://127.0.0.1:9091;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
}
location /metrics/ {
    auth_request /metrics-auth/validate;
    auth_request_set \$auth_status \$upstream_status;
    proxy_pass http://127.0.0.1:19999/;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_redirect http://127.0.0.1:19999/ https://${MATRIX_DOMAIN}/metrics/;
}
SNIPPET
if ! grep -q "metrics-netdata.conf" "$MATRIX_VHOST" 2>/dev/null; then
  sed -i '/listen 443 ssl http2;/a\    include /etc/nginx/snippets/metrics-netdata.conf;' "$MATRIX_VHOST"
  echo "  Added metrics-netdata include."
else
  echo "  metrics-netdata already included."
fi

echo "[6] Ensure metrics-auth-proxy is running..."
systemctl enable metrics-auth-proxy 2>/dev/null || true
systemctl start metrics-auth-proxy 2>/dev/null || true
echo "  metrics-auth-proxy enabled and started."

echo "[7] Nginx test and reload..."
nginx -t && systemctl reload nginx
echo "  Nginx reloaded."

echo "[8] Optional: purge Prometheus and Grafana packages (frees disk)..."
echo "  To remove packages later run: sudo apt-get purge -y prometheus prometheus-node-exporter grafana"
echo "  (Skipping auto-purge; uncomment below to purge now.)"
# apt-get purge -y prometheus prometheus-node-exporter grafana 2>/dev/null || true

echo "Done. Netdata at https://${MATRIX_DOMAIN}/metrics/ (log in with Matrix account)."
