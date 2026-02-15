#!/usr/bin/env bash
# Fix 502 when opening /metrics/ (Netdata): use Netdata-recommended nginx subfolder config.
# Run on remote with sudo, e.g.:
#   (echo 'MATRIX_DOMAIN=matrix.timeways.net'; cat fix-netdata-502-nginx-remote.sh) | ./run-remote-sudo.sh lukano@timeways.net
set -e
MATRIX_DOMAIN="${MATRIX_DOMAIN:-matrix.timeways.net}"

echo "[1] Update /etc/nginx/snippets/metrics-netdata.conf (Netdata subfolder pattern)..."
mkdir -p /etc/nginx/snippets
cat > /etc/nginx/snippets/metrics-netdata.conf << SNIPPET
# Gated Netdata (auth_request via metrics-auth-proxy). Subfolder pattern per Netdata docs.
location = /metrics {
    return 301 /metrics/;
}
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
# Netdata subfolder: regex pass-through (per Netdata nginx reverse proxy docs)
location ~ ^/metrics/(?<ndpath>.*) {
    auth_request /metrics-auth/validate;
    auth_request_set \$auth_status \$upstream_status;
    proxy_redirect off;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Server \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Connection "keep-alive";
    proxy_pass_request_headers on;
    proxy_store off;
    proxy_pass http://127.0.0.1:19999/\$ndpath\$is_args\$args;
    gzip on;
    gzip_proxied any;
    gzip_types *;
}
SNIPPET
echo "  Written."

echo "[2] Nginx test and reload..."
nginx -t && systemctl reload nginx
echo "  Reloaded."

echo "Done. Try https://${MATRIX_DOMAIN}/metrics/ (log in with Matrix)."
