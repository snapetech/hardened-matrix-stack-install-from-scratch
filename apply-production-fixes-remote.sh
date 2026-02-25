#!/usr/bin/env bash
# Production fix checklist: apply hardened-matrix-stack fixes on a live server.
#
# Sync repo first, then run (once; avoid retries due to fail2ban):
#   rsync -avz --exclude .git ./ lukano@timeways.net:~/hardened-matrix-stack/
#   (echo 'REPO_DIR=/home/lukano/hardened-matrix-stack'; cat apply-production-fixes-remote.sh) | ./run-remote-sudo.sh lukano@timeways.net
#
# Or on the host: sudo REPO_DIR=/path/to/repo bash apply-production-fixes-remote.sh
set -e
REPO_DIR="${REPO_DIR:-}"
if [ -z "$REPO_DIR" ]; then
  for d in /home/lukano/hardened-matrix-stack /root/hardened-matrix-stack "$(dirname "$0")"; do
    [ -f "$d/setup-from-scratch.sh" ] && REPO_DIR="$d" && break
  done
fi
[ -n "$REPO_DIR" ] && [ -d "$REPO_DIR" ] || { echo "REPO_DIR not set or missing. Set REPO_DIR to repo path." >&2; exit 1; }

# Detect server name and matrix domain from nginx or synapse
MATRIX_DOMAIN="${MATRIX_DOMAIN:-}"
SERVER_NAME="${SERVER_NAME:-}"
if [ -f /etc/nginx/sites-available/matrix ]; then
  MATRIX_DOMAIN="${MATRIX_DOMAIN:-$(grep -oE 'server_name[[:space:]]+[^;]+' /etc/nginx/sites-available/matrix | head -1 | awk '{print $2}' | tr -d ';')}"
fi
if [ -z "$SERVER_NAME" ] && [ -n "$MATRIX_DOMAIN" ]; then
  SERVER_NAME="${MATRIX_DOMAIN%%.*}"
  [ "$SERVER_NAME" = "matrix" ] && SERVER_NAME="${MATRIX_DOMAIN#*.}" || true
fi
[ -z "$SERVER_NAME" ] && SERVER_NAME="${MATRIX_DOMAIN:-timeways.net}"
[ -z "$MATRIX_DOMAIN" ] && MATRIX_DOMAIN="matrix.timeways.net"

echo "[1] SSL: chmod 600 self-signed certs (if present)..."
for f in /etc/nginx/ssl/matrix-selfsigned.crt /etc/nginx/ssl/matrix-selfsigned.key; do
  [ -f "$f" ] && chmod 600 "$f" && echo "  $f -> 600" || true
done

echo "[2] Moderation bots env: ensure MOD_BOT_ENV_FILE location and perms..."
MOD_BOT_ENV_FILE="${MOD_BOT_ENV_FILE:-/root/.config/matrix-stack/ensure-moderation-bots.env}"
mkdir -p "$(dirname "$MOD_BOT_ENV_FILE")"
# Migrate from old location if present (repo or /opt)
for old in "$REPO_DIR/.ensure-moderation-bots-env" /opt/matrix-stack/.ensure-moderation-bots-env /root/.ensure-moderation-bots-env; do
  if [ -f "$old" ]; then
    grep -q 'MATRIX_ADMIN_USER' "$old" 2>/dev/null || echo "MATRIX_ADMIN_USER=${ADMIN_USER:-admin}" >> "$old"
    cp -a "$old" "$MOD_BOT_ENV_FILE" 2>/dev/null || cat "$old" > "$MOD_BOT_ENV_FILE"
    chmod 600 "$MOD_BOT_ENV_FILE"
    echo "  Migrated $old -> $MOD_BOT_ENV_FILE"
    break
  fi
done
if [ -f "$MOD_BOT_ENV_FILE" ]; then
  chmod 600 "$MOD_BOT_ENV_FILE"
  grep -q 'MATRIX_ADMIN_USER' "$MOD_BOT_ENV_FILE" 2>/dev/null || echo "MATRIX_ADMIN_USER=${ADMIN_USER:-admin}" >> "$MOD_BOT_ENV_FILE"
fi

echo "[3] Element Call: docker-compose.yml use \${LIVEKIT_FULL_ACCESS_HOMESERVERS}..."
EC_COMPOSE="/opt/element-call/docker-compose.yml"
if [ -f "$EC_COMPOSE" ]; then
  if grep -q 'LIVEKIT_FULL_ACCESS_HOMESERVERS=\*' "$EC_COMPOSE" 2>/dev/null; then
    sed -i 's/LIVEKIT_FULL_ACCESS_HOMESERVERS=\*/LIVEKIT_FULL_ACCESS_HOMESERVERS=\${LIVEKIT_FULL_ACCESS_HOMESERVERS}/g' "$EC_COMPOSE"
    echo "  Replaced hard-coded * with variable"
  fi
  # Ensure repo version is copied if it uses variable
  [ -f "$REPO_DIR/element-call/docker-compose.yml" ] && cp "$REPO_DIR/element-call/docker-compose.yml" "$EC_COMPOSE"
fi

echo "[4] Element Call .env: set LIVEKIT_FULL_ACCESS_HOMESERVERS to homeserver..."
EC_ENV="/opt/element-call/.env"
if [ -f "$EC_ENV" ]; then
  if grep -q '^LIVEKIT_FULL_ACCESS_HOMESERVERS=' "$EC_ENV"; then
    sed -i "s|^LIVEKIT_FULL_ACCESS_HOMESERVERS=.*|LIVEKIT_FULL_ACCESS_HOMESERVERS=$SERVER_NAME|" "$EC_ENV"
  else
    echo "LIVEKIT_FULL_ACCESS_HOMESERVERS=$SERVER_NAME" >> "$EC_ENV"
  fi
  echo "  LIVEKIT_FULL_ACCESS_HOMESERVERS=$SERVER_NAME"
fi

echo "[5] Nginx: element-call-livekit.conf with limit_req and 401 guard..."
LIVEKIT_SNIPPET="/etc/nginx/snippets/element-call-livekit.conf"
# Remove duplicate rate-limit-zones if we added it but login_zone already existed (e.g. synapse-rate-limit-zones.conf)
if [ -f /etc/nginx/conf.d/rate-limit-zones.conf ] && [ -f /etc/nginx/conf.d/synapse-rate-limit-zones.conf ]; then
  rm -f /etc/nginx/conf.d/rate-limit-zones.conf
  sed -i '/include \/etc\/nginx\/conf.d\/rate-limit-zones.conf/d' /etc/nginx/nginx.conf 2>/dev/null || true
  echo "  Removed duplicate rate-limit-zones.conf"
fi
# Ensure login_zone exists (snippet uses it). Only add if not already defined anywhere.
if ! grep -rq 'zone=login_zone:' /etc/nginx/ 2>/dev/null; then
  if [ -f "$REPO_DIR/nginx-synapse-rate-limit-zones.conf" ] && [ -d /etc/nginx/conf.d ]; then
    cp "$REPO_DIR/nginx-synapse-rate-limit-zones.conf" /etc/nginx/conf.d/rate-limit-zones.conf
    if ! grep -q 'include.*rate-limit-zones\|login_zone' /etc/nginx/nginx.conf 2>/dev/null; then
      [ -f /etc/nginx/nginx.conf ] && grep -q 'http {' /etc/nginx/nginx.conf && \
        sed -i '/http {/a\    include /etc/nginx/conf.d/rate-limit-zones.conf;' /etc/nginx/nginx.conf
    fi
    echo "  Added rate-limit-zones (login_zone was not defined)"
  fi
else
  echo "  login_zone already defined in nginx; skipping rate-limit-zones"
fi
# Regenerate full snippet with limit_req and 401 in /livekit/jwt/
cat > "$LIVEKIT_SNIPPET" << 'SNIP'
# Redirect no-trailing-slash to slash so clients hitting /livekit/jwt or /livekit/sfu still work
location = /livekit/jwt { return 301 /livekit/jwt/; }
location = /livekit/sfu { return 301 /livekit/sfu/; }
location ^~ /livekit/jwt/ {
    limit_req zone=login_zone burst=10 nodelay;
    if ($http_authorization = "") { return 401; }
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_pass http://127.0.0.1:6080/;
}
location ^~ /livekit/sfu/ {
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_send_timeout 120;
    proxy_read_timeout 120;
    proxy_buffering off;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_pass http://127.0.0.1:7880/;
}
SNIP
echo "  element-call-livekit.conf updated (limit_req + 401 on /livekit/jwt/)"

echo "[6] ensure-moderation-bots cron: source new env and MATRIX_ADMIN_USER..."
SCRIPT_CRON=". $MOD_BOT_ENV_FILE 2>/dev/null; [ -n \"\$ADMIN_PASSWORD\" ] || exit 0; export SYNAPSE_BASE_URL MATRIX_SERVER_NAME MATRIX_ADMIN_USER ADMIN_PASSWORD; $REPO_DIR/k8s-qa/ensure-moderation-bots-in-rooms.sh"
CRON_CMD="*/10 * * * * $SCRIPT_CRON"
(crontab -l 2>/dev/null | grep -v "ensure-moderation-bots-in-rooms" || true; echo "$CRON_CMD") | crontab -
echo "  Cron updated to source $MOD_BOT_ENV_FILE and export MATRIX_ADMIN_USER"

echo "[7] ensure-moderation-bots-in-rooms.sh: copy from repo (uses MATRIX_ADMIN_USER)..."
[ -f "$REPO_DIR/k8s-qa/ensure-moderation-bots-in-rooms.sh" ] && cp "$REPO_DIR/k8s-qa/ensure-moderation-bots-in-rooms.sh" /usr/local/sbin/ensure-moderation-bots-in-rooms.sh 2>/dev/null && chmod +x /usr/local/sbin/ensure-moderation-bots-in-rooms.sh && echo "  Copied to /usr/local/sbin" || true
# Cron can still point at repo script; if cron uses $REPO_DIR/k8s-qa/... that's fine

echo "[8] matrix-stack-healthcheck: detect docker compose vs docker-compose..."
if [ -f "$REPO_DIR/matrix-stack-healthcheck.sh" ]; then
  cp "$REPO_DIR/matrix-stack-healthcheck.sh" /usr/local/sbin/matrix-stack-healthcheck
  chmod +x /usr/local/sbin/matrix-stack-healthcheck
  echo "  Healthcheck script updated"
fi

echo "[9] Monitoring: stop backend not in use (netdata vs prometheus)..."
MATRIX_VHOST="/etc/nginx/sites-available/matrix"
if grep -q "metrics-netdata\|netdata" "$MATRIX_VHOST" 2>/dev/null; then
  systemctl stop prometheus 2>/dev/null || true
  systemctl disable prometheus 2>/dev/null || true
  systemctl stop node_exporter 2>/dev/null || true
  systemctl disable node_exporter 2>/dev/null || true
  echo "  Using Netdata; stopped prometheus/node_exporter"
elif grep -q "metrics-auth\|prometheus" "$MATRIX_VHOST" 2>/dev/null; then
  systemctl stop netdata 2>/dev/null || true
  systemctl disable netdata 2>/dev/null || true
  echo "  Using Prometheus; stopped netdata"
else
  echo "  No metrics snippet detected; leaving monitoring as-is"
fi

echo "[10] Nginx test and reload..."
nginx -t && systemctl reload nginx
echo "  Nginx reloaded"

echo "[11] Element Call: restart with new .env..."
if [ -d /opt/element-call ] && [ -f /opt/element-call/docker-compose.yml ]; then
  (cd /opt/element-call && (docker compose down 2>/dev/null || docker-compose down 2>/dev/null) || true)
  (cd /opt/element-call && (docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null) || true)
  echo "  Element Call restarted"
fi

echo "Done. Ensure $MOD_BOT_ENV_FILE has ADMIN_PASSWORD, MATRIX_ADMIN_USER, SYNAPSE_BASE_URL, MATRIX_SERVER_NAME (and chmod 600)."
