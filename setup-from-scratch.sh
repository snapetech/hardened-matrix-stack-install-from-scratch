#!/bin/bash
# First-time Matrix stack setup for a fresh server (Debian/Ubuntu).
# Installs and configures: Postgres, Synapse, nginx, TLS (certbot), coturn,
# Prometheus, Grafana, metrics-auth proxy, fail2ban, backup cron,
# Element Call (LiveKit Docker), Mjolnir, Maubot, Discord bridge.
# Prompts interactively for domain, server name, email, and options.
#
# Usage: sudo ./setup-from-scratch.sh
#    or: copy this repo to the server and run from the repo root.
# Non-interactive (QA / automation): set NON_INTERACTIVE=1 and env vars (MATRIX_DOMAIN,
# SERVER_NAME, ROOT_DOMAIN, LE_EMAIL, FEDERATION, INSTALL_*). Use USE_SELF_SIGNED_CERT=1
# to skip Let's Encrypt and use a self-signed cert (e.g. when no real DNS).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Where to find config templates (same dir as this script)
REPO_DIR="${REPO_DIR:-$SCRIPT_DIR}"

# --- Defaults (overridden by prompts or env when NON_INTERACTIVE=1) ---
MATRIX_DOMAIN="${MATRIX_DOMAIN:-}"
SERVER_NAME="${SERVER_NAME:-}"
ROOT_DOMAIN="${ROOT_DOMAIN:-}"
LE_EMAIL="${LE_EMAIL:-}"
FEDERATION="${FEDERATION:-n}"
INSTALL_COTURN="${INSTALL_COTURN:-y}"
INSTALL_MONITORING="${INSTALL_MONITORING:-y}"
INSTALL_ELEMENT_CALL="${INSTALL_ELEMENT_CALL:-n}"
INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN:-y}"
INSTALL_BACKUP_CRON="${INSTALL_BACKUP_CRON:-y}"
INSTALL_MJOLNIR="${INSTALL_MJOLNIR:-n}"
INSTALL_MAUBOT="${INSTALL_MAUBOT:-n}"
INSTALL_DISCORD="${INSTALL_DISCORD:-n}"
INSTALL_METRICS_AUTH="${INSTALL_METRICS_AUTH:-y}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"

# --- State ---
SYNAPSE_DB_PASSWORD=""
TURN_SECRET=""
REGISTRATION_SHARED_SECRET=""
LIVEKIT_KEY=""
LIVEKIT_SECRET=""
DISCORD_BOT_TOKEN=""

die() { echo "Error: $*" >&2; exit 1; }
prompt() { local v="$1"; local def="$2"; local p="$3"; shift 3; read -p "$p [$def]: " "$v"; eval "[ -z \"\$$v\" ] && $v=\"$def\""; }
yesno() { local v="$1"; local def="$2"; local p="$3"; read -p "$p (y/n) [$def]: " "$v"; eval "[ -z \"\$$v\" ] && $v=\"$def\""; eval "$v=\$(echo \$$v | tr '[:upper:]' '[:lower:]')"; }
# Run command as postgres user (works with or without sudo, e.g. in containers)
run_as_postgres() {
  if command -v sudo &>/dev/null; then
    sudo -u postgres "$@"
  else
    # Use -- so su does not parse command args (e.g. psql -t, createuser -D) as su options
    su postgres -s /bin/bash -c 'exec "$@"' -- _ "$@"
  fi
}

# ========== No-systemd (container) support ==========
# When systemd is not running (e.g. Docker), start/stop services manually so the script runs front-to-back.
NO_SYSTEMD=0
if [ ! -d /run/systemd/system ] || ! systemctl is-system-running &>/dev/null; then
  NO_SYSTEMD=1
  echo "  (No systemd detected; will start services manually for container/QA.)"
fi
# Allow Debian invoke-rc.d to start services when we run them manually (policy-rc.d often blocks in containers)
allow_container_services() {
  if [ "$NO_SYSTEMD" = "1" ] && [ -x /usr/sbin/policy-rc.d ]; then
    echo 'exit 0' > /usr/sbin/policy-rc.d
    chmod +x /usr/sbin/policy-rc.d
  fi
}
svc_enable() { [ "$NO_SYSTEMD" = "0" ] && systemctl enable "$1" 2>/dev/null || true; }
svc_stop() {
  local s="$1"
  if [ "$NO_SYSTEMD" = "1" ]; then
    case "$s" in
      nginx) nginx -s stop 2>/dev/null || true ;;
      matrix-synapse) [ -f /run/matrix-synapse.pid ] && (kill "$(cat /run/matrix-synapse.pid)" 2>/dev/null || true); rm -f /run/matrix-synapse.pid ;;
      *) true ;;
    esac
  else
    systemctl stop "$s" 2>/dev/null || true
  fi
}
svc_start() {
  local s="$1"
  if [ "$NO_SYSTEMD" = "1" ]; then
    case "$s" in
      postgresql)
        allow_container_services
        if ! pg_lsclusters -h 2>/dev/null | grep -q .; then
          # No cluster yet (e.g. container postinst skipped start); create one
          for ver in 15 16 14 17; do
            [ -d /usr/lib/postgresql/$ver ] && pg_createcluster "$ver" main 2>/dev/null && break
          done
        fi
        pg_lsclusters -h 2>/dev/null | while read -r ver _ _ _ _ _; do
          pg_ctlcluster "$ver" main start 2>/dev/null || true
          break
        done
        for _ in 1 2 3 4 5 6 7 8 9 10; do
          run_as_postgres psql -tAc "SELECT 1" 2>/dev/null && break
          sleep 1
        done
        ;;
      nginx) nginx 2>/dev/null || true ;;
      matrix-synapse)
        mkdir -p /run
        start-stop-daemon --start --background --pidfile /run/matrix-synapse.pid --make-pidfile --chuid matrix-synapse:matrix-synapse --exec /usr/bin/python3 -- -m synapse.app.homeserver -c /etc/matrix-synapse/homeserver.yaml 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
          if curl -s -o /dev/null http://127.0.0.1:8008/health 2>/dev/null; then break; fi
          sleep 1
        done
        ;;
      coturn) cmd=$(command -v turnserver 2>/dev/null) && [ -x "$cmd" ] && ($cmd -c /etc/turnserver.conf --daemon 2>/dev/null || true) || true ;;
      prometheus) [ -x /usr/bin/prometheus ] && (prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus --web.listen-address=127.0.0.1:9090 &) 2>/dev/null || true ;;
      prometheus-node-exporter) [ -x /usr/bin/prometheus-node-exporter ] && (prometheus-node-exporter &) 2>/dev/null || true ;;
      grafana-server) [ -x /usr/sbin/grafana-server ] && (grafana-server --homepath=/usr/share/grafana &) 2>/dev/null || true ;;
      metrics-auth-proxy) [ -x /opt/metrics-auth/metrics-auth-proxy.py ] && (python3 /opt/metrics-auth/metrics-auth-proxy.py &) 2>/dev/null || true ;;
      fail2ban) fail2ban-client start 2>/dev/null || true ;;
      docker) [ -x /usr/bin/dockerd ] && (dockerd &) 2>/dev/null || true ;;
      *) true ;;
    esac
  else
    systemctl start "$s" 2>/dev/null || true
  fi
}
svc_restart() {
  local s="$1"
  if [ "$NO_SYSTEMD" = "1" ]; then
    svc_stop "$s"
    sleep 1
    svc_start "$s"
  else
    systemctl restart "$s" 2>/dev/null || true
  fi
}
svc_reload() {
  local s="$1"
  if [ "$NO_SYSTEMD" = "1" ]; then
    [ "$s" = "nginx" ] && nginx -s reload 2>/dev/null || true
  else
    systemctl reload "$s" 2>/dev/null || true
  fi
}

# ========== Phase 0: Requirements and prompts ==========
run_prompts() {
  echo "=== Matrix stack first-time setup ==="
  echo "Target: Debian/Ubuntu. Run as root or with sudo."
  echo ""

  if [ "$(id -u)" -ne 0 ]; then
    die "Run as root or with sudo."
  fi

  if [ "${NON_INTERACTIVE:-0}" = "1" ]; then
    # Non-interactive: require minimal env and apply defaults
    MATRIX_DOMAIN="${MATRIX_DOMAIN:-matrix.example.com}"
    SERVER_NAME="${SERVER_NAME:-example.com}"
    ROOT_DOMAIN="${ROOT_DOMAIN:-$SERVER_NAME}"
    LE_EMAIL="${LE_EMAIL:-admin@$SERVER_NAME}"
    for v in FEDERATION INSTALL_COTURN INSTALL_MONITORING INSTALL_ELEMENT_CALL INSTALL_FAIL2BAN INSTALL_BACKUP_CRON INSTALL_MJOLNIR INSTALL_MAUBOT INSTALL_DISCORD INSTALL_METRICS_AUTH; do
      eval "val=\$$v"; val="$(echo "${val:-}" | tr '[:upper:]' '[:lower:]')"
      case "$val" in ""|y|yes|1|true) eval "$v=y" ;; *) eval "$v=n" ;; esac
    done
    [ "$INSTALL_MONITORING" != "y" ] && INSTALL_METRICS_AUTH="n"
    ADMIN_USER="${ADMIN_USER:-admin}"
    echo "  (NON_INTERACTIVE=1: using MATRIX_DOMAIN=$MATRIX_DOMAIN SERVER_NAME=$SERVER_NAME)"
  else
    # Interactive prompts
    prompt MATRIX_DOMAIN "matrix.example.com" "Matrix client URL (hostname only, e.g. matrix.example.com):"
    prompt SERVER_NAME "example.com" "Matrix server name for MXIDs (e.g. example.com):"
    ROOT_DOMAIN="${ROOT_DOMAIN:-$SERVER_NAME}"
    prompt ROOT_DOMAIN "$SERVER_NAME" "Root domain for .well-known discovery (usually same as server name):"
    prompt LE_EMAIL "admin@$SERVER_NAME" "Email for Let's Encrypt (cert expiry notices):"
    yesno FEDERATION "n" "Enable federation (open to other Matrix servers)?"
    yesno INSTALL_COTURN "y" "Install coturn (TURN/STUN for voice/video)?"
    yesno INSTALL_MONITORING "y" "Install Prometheus + Grafana (metrics)?"
    yesno INSTALL_ELEMENT_CALL "n" "Install Element Call / LiveKit (Docker)?"
    yesno INSTALL_FAIL2BAN "y" "Install fail2ban (login brute-force protection)?"
    yesno INSTALL_BACKUP_CRON "y" "Install backup script and daily cron?"
    yesno INSTALL_MJOLNIR "n" "Install Mjolnir (moderation bot, Docker)?"
    yesno INSTALL_MAUBOT "n" "Install Maubot (plugin bot)?"
    yesno INSTALL_DISCORD "n" "Install Discord bridge (appservice)?"
    if [ "$INSTALL_MONITORING" = "y" ]; then
      yesno INSTALL_METRICS_AUTH "y" "Gate Prometheus/Grafana behind Synapse login (metrics-auth proxy)?"
    fi
    read -p "First admin Matrix user (localpart, e.g. admin) [admin]: " ADMIN_USER
    ADMIN_USER="${ADMIN_USER:-admin}"

    echo ""
    echo "Summary:"
    echo "  Matrix URL: https://$MATRIX_DOMAIN"
    echo "  Server name (MXID): $SERVER_NAME"
    echo "  .well-known on: $ROOT_DOMAIN"
    echo "  Federation: $FEDERATION | Coturn: $INSTALL_COTURN | Monitoring: $INSTALL_MONITORING | Element Call: $INSTALL_ELEMENT_CALL"
    echo "  Fail2ban: $INSTALL_FAIL2BAN | Backup: $INSTALL_BACKUP_CRON | Mjolnir: $INSTALL_MJOLNIR | Maubot: $INSTALL_MAUBOT | Discord: $INSTALL_DISCORD | Metrics-auth: $INSTALL_METRICS_AUTH"
    read -p "Continue? (y/n) [y]: " cont
    cont="${cont:-y}"
    [[ "$cont" =~ ^[yY] ]] || exit 0
  fi
}

# ========== Phase 1: Base packages ==========
install_base() {
  echo "[1/14] Installing base packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq apt-utils curl wget ca-certificates gnupg lsb-release \
    postgresql postgresql-client nginx certbot python3-certbot-nginx \
    python3 python3-pip python3-venv
  if [ "$INSTALL_COTURN" = "y" ]; then
    apt-get install -y -qq coturn
  fi
  if [ "$INSTALL_FAIL2BAN" = "y" ]; then
    apt-get install -y -qq fail2ban
  fi
}

# ========== Phase 2: Matrix.org Synapse repo + install ==========
install_synapse() {
  echo "[2/14] Installing Synapse..."
  if command -v matrix-synapse &>/dev/null 2>&1; then
    echo "  Synapse already installed, skipping."
    return 0
  fi
  # Key is provided as .gpg keyring (not .asc); see https://packages.matrix.org/debian/
  wget -qO /usr/share/keyrings/matrix-org-archive-keyring.gpg https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/matrix-org.list
  apt-get update -qq && apt-get install -y -qq matrix-synapse-py3
  svc_enable matrix-synapse
}

# ========== Phase 3: Postgres DB for Synapse ==========
setup_postgres() {
  echo "[3/14] Setting up PostgreSQL for Synapse..."
  svc_start postgresql
  SYNAPSE_DB_PASSWORD="${SYNAPSE_DB_PASSWORD:-$(openssl rand -hex 16)}"
  run_as_postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='synapse'" | grep -q 1 || run_as_postgres createuser -D -R -S synapse
  run_as_postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='synapse'" | grep -q 1 || run_as_postgres createdb -O synapse synapse
  run_as_postgres psql -c "ALTER USER synapse WITH PASSWORD '$SYNAPSE_DB_PASSWORD';" 2>/dev/null || true
  mkdir -p /etc/matrix-synapse/conf.d
  chown -R matrix-synapse:matrix-synapse /etc/matrix-synapse
  # database.yaml
  cat > /etc/matrix-synapse/conf.d/database.yaml << EOF
# Generated by setup-from-scratch.sh
database:
  name: psycopg2
  args:
    user: synapse
    password: $SYNAPSE_DB_PASSWORD
    database: synapse
    host: localhost
    port: 5432
    cp_min: 5
    cp_max: 10
EOF
  chmod 600 /etc/matrix-synapse/conf.d/database.yaml
  chown matrix-synapse:matrix-synapse /etc/matrix-synapse/conf.d/database.yaml
}

# ========== Phase 4: Synapse config (server_name, listener, registration, etc.) ==========
setup_synapse_config() {
  echo "[4/14] Configuring Synapse..."
  # server_name + public_baseurl
  cat > /etc/matrix-synapse/conf.d/server_name.yaml << EOF
server_name: "$SERVER_NAME"
public_baseurl: "https://$MATRIX_DOMAIN/"
EOF
  # registration off; shared secret allows register_new_matrix_user for first admin
  REGISTRATION_SHARED_SECRET="${REGISTRATION_SHARED_SECRET:-$(openssl rand -hex 32)}"
  cat > /etc/matrix-synapse/conf.d/registration.yaml << EOF
enable_registration: false
enable_registration_without_verification: false
registration_shared_secret: "$REGISTRATION_SHARED_SECRET"
EOF
  chmod 600 /etc/matrix-synapse/conf.d/registration.yaml
  chown matrix-synapse:matrix-synapse /etc/matrix-synapse/conf.d/registration.yaml
  # Listener: client-only (no federation) or client+federation
  if [ "$FEDERATION" = "y" ]; then
    RESOURCES="[client, federation]"
  else
    RESOURCES="[client]"
  fi
  cat > /etc/matrix-synapse/conf.d/listener.yaml << EOF
# Generated by setup-from-scratch.sh
enable_metrics: true
listeners:
  - bind_addresses: ['127.0.0.1', '::1']
    port: 8008
    type: http
    tls: false
    x_forwarded: true
    resources:
      - names: $RESOURCES
        compress: false
  - port: 9000
    type: metrics
    bind_addresses: ['127.0.0.1', '::1']
EOF
  # URL preview off, ip blacklist, no-federation whitelist
  [ -f "$REPO_DIR/synapse-url-preview.yaml" ] && cp "$REPO_DIR/synapse-url-preview.yaml" /etc/matrix-synapse/conf.d/45-url-preview.yaml || true
  [ -f "$REPO_DIR/synapse-ip-blacklist.yaml" ] && cp "$REPO_DIR/synapse-ip-blacklist.yaml" /etc/matrix-synapse/conf.d/46-ip-blacklist.yaml || true
  [ -f "$REPO_DIR/synapse-no-federation.yaml" ] && cp "$REPO_DIR/synapse-no-federation.yaml" /etc/matrix-synapse/conf.d/44-no-federation.yaml || true
  # Remove default listener from main config if it exists (we use conf.d)
  if [ -f /etc/matrix-synapse/homeserver.yaml ]; then
    python3 -c "
import yaml
p = '/etc/matrix-synapse/homeserver.yaml'
with open(p) as f: c = yaml.safe_load(f)
if c and 'listeners' in c:
  del c['listeners']
  with open(p, 'w') as f: yaml.dump(c, f, default_flow_style=False)
" 2>/dev/null || true
  fi
  chown -R matrix-synapse:matrix-synapse /etc/matrix-synapse/conf.d
  # Signing key is created by Synapse on first start if missing
  svc_start matrix-synapse
  svc_enable matrix-synapse
  echo "  Synapse configured (registration off, listener with x_forwarded)."
}

# ========== Phase 5: nginx + TLS (certbot or self-signed) ==========
setup_nginx_tls() {
  echo "[5/14] Configuring nginx and TLS..."
  # Stop nginx so certbot can bind 80 if needed
  svc_stop nginx

  SSL_CERT_PATH=""
  SSL_KEY_PATH=""
  SSL_OPTIONS_INCLUDE="include /etc/letsencrypt/options-ssl-nginx.conf;"
  if [ "${USE_SELF_SIGNED_CERT:-0}" = "1" ]; then
    # QA / no-DNS: self-signed cert (one cert for matrix domain; reuse for root if different)
    mkdir -p /etc/nginx/ssl
    SSL_CERT_PATH="/etc/nginx/ssl/matrix-selfsigned.crt"
    SSL_KEY_PATH="/etc/nginx/ssl/matrix-selfsigned.key"
    if [ ! -f "$SSL_KEY_PATH" ]; then
      openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$SSL_KEY_PATH" -out "$SSL_CERT_PATH" \
        -subj "/CN=$MATRIX_DOMAIN/O=Matrix QA"
      chmod 644 "$SSL_CERT_PATH" "$SSL_KEY_PATH"
    fi
    SSL_OPTIONS_INCLUDE="ssl_protocols TLSv1.2 TLSv1.3; ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;"
    echo "  Using self-signed cert (USE_SELF_SIGNED_CERT=1)."
  else
    # Cert for matrix domain
    certbot certonly --nginx -d "$MATRIX_DOMAIN" --email "$LE_EMAIL" --agree-tos --non-interactive --redirect 2>/dev/null || certbot certonly --standalone -d "$MATRIX_DOMAIN" --email "$LE_EMAIL" --agree-tos --non-interactive 2>/dev/null || true
    # Cert for root domain if different (for .well-known)
    if [ "$ROOT_DOMAIN" != "$MATRIX_DOMAIN" ]; then
      certbot certonly --nginx -d "$ROOT_DOMAIN" --email "$LE_EMAIL" --agree-tos --non-interactive 2>/dev/null || certbot certonly --standalone -d "$ROOT_DOMAIN" --email "$LE_EMAIL" --agree-tos --non-interactive 2>/dev/null || true
    fi
    SSL_CERT_PATH="/etc/letsencrypt/live/$MATRIX_DOMAIN/fullchain.pem"
    SSL_KEY_PATH="/etc/letsencrypt/live/$MATRIX_DOMAIN/privkey.pem"
  fi

  # Matrix site: 80 -> 301 https, 443 -> proxy to Synapse + static well-known
  mkdir -p /var/www/matrix-well-known/.well-known/matrix
  echo "{\"m.homeserver\":{\"base_url\":\"https://$MATRIX_DOMAIN/\"}}" > /var/www/matrix-well-known/.well-known/matrix/client
  chown -R www-data:www-data /var/www/matrix-well-known
  # Well-known for server (federation)
  if [ "$FEDERATION" = "y" ]; then
    echo "{\"m.server\":\"$MATRIX_DOMAIN:443\"}" > /var/www/matrix-well-known/.well-known/matrix/server
  fi
  # Root domain cert paths (same as matrix when self-signed or when root == matrix)
  ROOT_SSL_CERT="$SSL_CERT_PATH"
  ROOT_SSL_KEY="$SSL_KEY_PATH"
  if [ "$ROOT_DOMAIN" != "$MATRIX_DOMAIN" ] && [ "${USE_SELF_SIGNED_CERT:-0}" != "1" ]; then
    ROOT_SSL_CERT="/etc/letsencrypt/live/$ROOT_DOMAIN/fullchain.pem"
    ROOT_SSL_KEY="/etc/letsencrypt/live/$ROOT_DOMAIN/privkey.pem"
  fi
  # nginx sites: minimal matrix 80+443 (variables expanded)
  cat > /etc/nginx/sites-available/matrix << NGINX_MATRIX
# Generated by setup-from-scratch.sh
server {
    listen 80;
    listen [::]:80;
    server_name $MATRIX_DOMAIN $ROOT_DOMAIN;
    location /.well-known/matrix/client {
        default_type application/json;
        add_header Access-Control-Allow-Origin * always;
        alias /var/www/matrix-well-known/.well-known/matrix/client;
    }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl http2;
    server_name $MATRIX_DOMAIN;
    ssl_certificate $SSL_CERT_PATH;
    ssl_certificate_key $SSL_KEY_PATH;
    $SSL_OPTIONS_INCLUDE
    client_max_body_size 50M;
    location /.well-known/matrix/client {
        default_type application/json;
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Methods "GET, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Origin, X-Requested-With, Content-Type, Accept, Authorization" always;
        alias /var/www/matrix-well-known/.well-known/matrix/client;
    }
    location /_matrix { proxy_pass http://127.0.0.1:8008; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$remote_addr; proxy_set_header X-Forwarded-Proto \$scheme; proxy_http_version 1.1; }
    location /_synapse { proxy_pass http://127.0.0.1:8008; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$remote_addr; proxy_set_header X-Forwarded-Proto \$scheme; proxy_http_version 1.1; }
    location / { return 200 'OK'; add_header Content-Type text/plain; }
}
NGINX_MATRIX
  if [ "$ROOT_DOMAIN" != "$MATRIX_DOMAIN" ]; then
    cat > /etc/nginx/sites-available/root-wellknown << NGINX_ROOT
server {
    listen 443 ssl http2;
    server_name $ROOT_DOMAIN;
    ssl_certificate $ROOT_SSL_CERT;
    ssl_certificate_key $ROOT_SSL_KEY;
    $SSL_OPTIONS_INCLUDE
    location = /.well-known/matrix/client {
        default_type application/json;
        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Origin, X-Requested-With, Content-Type, Accept, Authorization" always;
        return 200 '{"m.homeserver":{"base_url":"https://$MATRIX_DOMAIN/"}}';
    }
    location / { return 302 https://$MATRIX_DOMAIN\$request_uri; }
}
NGINX_ROOT
    ln -sf /etc/nginx/sites-available/root-wellknown /etc/nginx/sites-enabled/ 2>/dev/null || true
  fi
  ln -sf /etc/nginx/sites-available/matrix /etc/nginx/sites-enabled/ 2>/dev/null || true
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
  nginx -t && svc_enable nginx && svc_start nginx
  echo "  nginx + TLS configured. Test: https://$MATRIX_DOMAIN/_matrix/client/versions"
}

# ========== Phase 6: Coturn (TURN secret) ==========
setup_coturn() {
  echo "[6/14] Configuring coturn..."
  if [ "$INSTALL_COTURN" != "y" ]; then return 0; fi
  TURN_SECRET="${TURN_SECRET:-$(openssl rand -hex 32)}"
  echo -n "$TURN_SECRET" > /root/.matrix-turn-secret
  chmod 600 /root/.matrix-turn-secret
  # Enable coturn
  sed -i 's/^#\?TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn 2>/dev/null || true
  # Basic turnserver.conf (user the script can append to)
  if [ ! -f /etc/turnserver.conf ] || ! grep -q "matrix-setup" /etc/turnserver.conf 2>/dev/null; then
    cat >> /etc/turnserver.conf << EOF
# matrix-setup-from-scratch
listening-port=3478
tls-listening-port=5349
use-auth-secret
static-auth-secret=$(cat /root/.matrix-turn-secret)
realm=$SERVER_NAME
EOF
  fi
  svc_enable coturn
  svc_start coturn
  # Synapse turn config
  cat > /etc/matrix-synapse/conf.d/turn.yaml << EOF
turn_uris:
  - "turn:$MATRIX_DOMAIN:3478?transport=udp"
  - "turn:$MATRIX_DOMAIN:3478?transport=tcp"
turn_shared_secret: "$(cat /root/.matrix-turn-secret)"
turn_user_lifetime: 86400000
turn_allow_guests: false
EOF
  chown matrix-synapse:matrix-synapse /etc/matrix-synapse/conf.d/turn.yaml
  svc_restart matrix-synapse
  echo "  Coturn enabled; TURN secret in /root/.matrix-turn-secret"
}

# ========== Phase 7: Optional monitoring (Prometheus + Grafana) ==========
setup_monitoring() {
  echo "[7/14] Optional: Prometheus + Grafana..."
  if [ "$INSTALL_MONITORING" != "y" ]; then return 0; fi
  apt-get install -y -qq prometheus prometheus-node-exporter 2>/dev/null || true
  # Synapse metrics already in listener; ensure scrape config
  mkdir -p /etc/prometheus
  [ -f "$REPO_DIR/prometheus-full.yml" ] && sed "s/matrix.example.com/$MATRIX_DOMAIN/g;s/example.com/$SERVER_NAME/g" "$REPO_DIR/prometheus-full.yml" > /etc/prometheus/prometheus.yml || true
  [ -f "$REPO_DIR/prometheus-alerts.yml" ] && cp "$REPO_DIR/prometheus-alerts.yml" /etc/prometheus/ || true
  svc_enable prometheus
  svc_enable prometheus-node-exporter
  svc_start prometheus
  svc_start prometheus-node-exporter
  # Grafana
  if ! command -v grafana-server &>/dev/null; then
    wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor -o /usr/share/keyrings/grafana.gpg
    echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
    apt-get update -qq && apt-get install -y -qq grafana
  fi
  mkdir -p /etc/grafana/provisioning/dashboards /etc/grafana/provisioning/datasources
  [ -f "$REPO_DIR/grafana/provisioning/datasources/prometheus.yml" ] && cp "$REPO_DIR/grafana/provisioning/datasources/prometheus.yml" /etc/grafana/provisioning/datasources/ || true
  [ -f "$REPO_DIR/grafana/dashboards/matrix-overview.json" ] && mkdir -p /etc/grafana/provisioning/dashboards/matrix && cp "$REPO_DIR/grafana/dashboards/matrix-overview.json" /etc/grafana/provisioning/dashboards/matrix/ || true
  [ -f "$REPO_DIR/grafana/provisioning/dashboards/dashboards.yml" ] && sed 's|path:.*|path: /etc/grafana/provisioning/dashboards/matrix|' "$REPO_DIR/grafana/provisioning/dashboards/dashboards.yml" > /etc/grafana/provisioning/dashboards/dashboards.yml || true
  [ -f "$REPO_DIR/grafana/conf.d/anonymous.ini" ] && mkdir -p /etc/grafana/conf.d && cp "$REPO_DIR/grafana/conf.d/anonymous.ini" /etc/grafana/conf.d/ || true
  svc_enable grafana-server
  svc_start grafana-server
  echo "  Prometheus + Grafana installed (Prometheus on :9090, Grafana on :3000)."
}

# ========== Phase 8: Metrics-auth proxy (gate Prometheus/Grafana behind Synapse login) ==========
setup_metrics_auth() {
  echo "[8/14] Metrics-auth proxy (gate metrics behind Synapse login)..."
  if [ "$INSTALL_MONITORING" != "y" ] || [ "$INSTALL_METRICS_AUTH" != "y" ]; then return 0; fi
  mkdir -p /opt/metrics-auth
  [ -f "$REPO_DIR/metrics-auth-proxy.py" ] && cp "$REPO_DIR/metrics-auth-proxy.py" /opt/metrics-auth/ && chmod 755 /opt/metrics-auth/metrics-auth-proxy.py
  [ -f "$REPO_DIR/metrics-auth-proxy.service" ] && sed "s|https://matrix.example.com|https://$MATRIX_DOMAIN|g" "$REPO_DIR/metrics-auth-proxy.service" > /etc/systemd/system/metrics-auth-proxy.service
  [ "$NO_SYSTEMD" = "0" ] && systemctl daemon-reload 2>/dev/null || true
  svc_enable metrics-auth-proxy
  svc_start metrics-auth-proxy
  # Bind Prometheus to localhost and set external-url for subpath
  if [ -f /etc/default/prometheus ]; then
    grep -q "web.listen-address" /etc/default/prometheus 2>/dev/null || echo 'ARGS="--web.listen-address=127.0.0.1:9090 --web.external-url=https://'"$MATRIX_DOMAIN"'/metrics/ --web.route-prefix=/"' >> /etc/default/prometheus
  fi
  # Grafana: serve from subpath /metrics/grafana
  mkdir -p /etc/grafana/conf.d
  if [ ! -f /etc/grafana/conf.d/subpath.ini ]; then
    cat > /etc/grafana/conf.d/subpath.ini << EOF
[server]
root_url = https://$MATRIX_DOMAIN/metrics/grafana
serve_from_sub_path = true
EOF
    svc_restart grafana-server
  fi
  # Nginx: add metrics-auth and /metrics/ and /metrics/grafana/ to matrix 443 server block
  mkdir -p /etc/nginx/snippets
  if [ -f "$REPO_DIR/nginx-metrics-auth.conf" ] && ! grep -q "metrics-auth/validate" /etc/nginx/sites-available/matrix 2>/dev/null; then
    METRICS_SNIPPET="/etc/nginx/snippets/metrics-grafana.conf"
    cat > "$METRICS_SNIPPET" << EOF
# Gated metrics (auth_request via metrics-auth-proxy)
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
    proxy_pass http://127.0.0.1:9090/;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_redirect http://127.0.0.1:9090/ https://$MATRIX_DOMAIN/metrics/;
}
location /metrics/grafana/ {
    auth_request /metrics-auth/validate;
    auth_request_set \$auth_status \$upstream_status;
    proxy_pass http://127.0.0.1:3000/;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Prefix /metrics/grafana;
    proxy_redirect http://127.0.0.1:3000/ https://$MATRIX_DOMAIN/metrics/grafana/;
}
EOF
    # Insert include before "location /_matrix" in the 443 server block
    sed -i '/listen 443 ssl;/a\    include /etc/nginx/snippets/metrics-grafana.conf;' /etc/nginx/sites-available/matrix
    nginx -t && svc_reload nginx
  fi
  echo "  Metrics-auth proxy installed. Metrics at https://$MATRIX_DOMAIN/metrics/ (login with Matrix account)."
}

# ========== Phase 9: Element Call / LiveKit (Docker) ==========
setup_element_call() {
  echo "[9/14] Element Call / LiveKit (Docker)..."
  if [ "$INSTALL_ELEMENT_CALL" != "y" ]; then return 0; fi
  # Install Docker if not present
  if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
    svc_enable docker
    svc_start docker
  fi
  if ! command -v docker compose &>/dev/null && ! docker-compose --version &>/dev/null 2>&1; then
    apt-get install -y -qq docker-compose-plugin 2>/dev/null || true
  fi
  mkdir -p /opt/element-call
  LIVEKIT_KEY="${LIVEKIT_KEY:-$(openssl rand -hex 16)}"
  LIVEKIT_SECRET="${LIVEKIT_SECRET:-$(openssl rand -base64 32)}"
  # LiveKit config
  if [ -f "$REPO_DIR/element-call/livekit.yaml.template" ]; then
    sed "s/LIVEKIT_KEY_PLACEHOLDER/$LIVEKIT_KEY/g;s/LIVEKIT_SECRET_PLACEHOLDER/$LIVEKIT_SECRET/g" "$REPO_DIR/element-call/livekit.yaml.template" > /opt/element-call/livekit.yaml
  else
    cat > /opt/element-call/livekit.yaml << EOF
port: 7880
rtc:
  port_range_start: 50000
  port_range_end: 50200
  tcp_port: 7881
  use_external_ip: true
keys:
  $LIVEKIT_KEY: "$LIVEKIT_SECRET"
EOF
  fi
  # .env for lk-jwt-service (LIVEKIT_URL must be wss://matrix-rtc host or same host /livekit/sfu)
  MATRIX_RTC_HOST="${MATRIX_RTC_HOST:-$MATRIX_DOMAIN}"
  cat > /opt/element-call/.env << EOF
LIVEKIT_KEY=$LIVEKIT_KEY
LIVEKIT_SECRET=$LIVEKIT_SECRET
LIVEKIT_URL=wss://$MATRIX_RTC_HOST/livekit/sfu
LIVEKIT_JWT_URL=https://$MATRIX_RTC_HOST/livekit/jwt
EOF
  [ -f "$REPO_DIR/element-call/docker-compose.yml" ] && cp "$REPO_DIR/element-call/docker-compose.yml" /opt/element-call/
  # Fix auth-service LIVEKIT_URL in compose (env sub is from .env; ensure host is correct)
  sed -i "s|wss://MATRIX_RTC_HOST/livekit/sfu|wss://$MATRIX_RTC_HOST/livekit/sfu|g" /opt/element-call/docker-compose.yml 2>/dev/null || true
  # Start containers
  (cd /opt/element-call && docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null || true)
  # Synapse: experimental Element Call + MSCs (MSC3266, MSC4222, MSC4140)
  cat > /etc/matrix-synapse/conf.d/experimental-element-call.yaml << EOF
# Element Call / MatrixRTC (LiveKit)
experimental_features:
  msc3266_enabled: true
  msc4222_enabled: true
max_event_delay_duration: 24h
rc_message:
  per_second: 0.5
  burst_count: 30
rc_delayed_event_mgmt:
  per_second: 1
  burst_count: 20
EOF
  # Synapse: announce LiveKit in .well-known (MSC4143 rtc_foci)
  CLIENT_WELLKNOWN="/var/www/matrix-well-known/.well-known/matrix/client"
  if [ -f "$CLIENT_WELLKNOWN" ]; then
    python3 -c "
import json
p = '$CLIENT_WELLKNOWN'
with open(p) as f: d = json.load(f)
d['org.matrix.msc4143.rtc_foci'] = [{'type': 'livekit', 'livekit_service_url': 'https://$MATRIX_RTC_HOST/livekit/jwt'}]
with open(p, 'w') as f: json.dump(d, f, indent=2)
" 2>/dev/null || true
  fi
  # Nginx: /livekit/jwt and /livekit/sfu on matrix 443 server block
  if ! grep -q "livekit/jwt" /etc/nginx/sites-available/matrix 2>/dev/null; then
    LIVEKIT_SNIPPET="/etc/nginx/snippets/element-call-livekit.conf"
    cat > "$LIVEKIT_SNIPPET" << EOF
location ^~ /livekit/jwt/ {
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_pass http://127.0.0.1:6080/;
}
location ^~ /livekit/sfu/ {
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_send_timeout 120;
    proxy_read_timeout 120;
    proxy_buffering off;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \"upgrade\";
    proxy_pass http://127.0.0.1:7880/;
}
EOF
    sed -i '/listen 443 ssl;/a\    include /etc/nginx/snippets/element-call-livekit.conf;' /etc/nginx/sites-available/matrix
    nginx -t && svc_reload nginx
  fi
  chown -R matrix-synapse:matrix-synapse /etc/matrix-synapse/conf.d
  svc_restart matrix-synapse
  echo "  Element Call backend at /opt/element-call (LiveKit + lk-jwt-service). .well-known updated for MSC4143."
}

# ========== Phase 10: Fail2ban + nginx hardening ==========
setup_fail2ban_nginx_hardening() {
  echo "[10/14] Fail2ban + nginx hardening..."
  if [ "$INSTALL_FAIL2BAN" = "y" ]; then
    [ -f "$REPO_DIR/fail2ban-matrix/filter.d/matrix-synapse-auth.conf" ] && cp "$REPO_DIR/fail2ban-matrix/filter.d/matrix-synapse-auth.conf" /etc/fail2ban/filter.d/
    [ -f "$REPO_DIR/fail2ban-matrix/jail.d/matrix-synapse-auth.conf" ] && mkdir -p /etc/fail2ban/jail.d && cp "$REPO_DIR/fail2ban-matrix/jail.d/matrix-synapse-auth.conf" /etc/fail2ban/jail.d/
    systemctl enable fail2ban && systemctl start fail2ban 2>/dev/null || true
    fail2ban-client reload 2>/dev/null || true
  fi
  # Rate-limit zones + hardening snippet (admin/metrics lockdown, rate-limited login)
  if [ -f "$REPO_DIR/nginx-synapse-rate-limit-zones.conf" ]; then
    mkdir -p /etc/nginx/conf.d /etc/nginx/snippets
    cp "$REPO_DIR/nginx-synapse-rate-limit-zones.conf" /etc/nginx/conf.d/
    [ -f "$REPO_DIR/nginx-synapse-hardening.conf" ] && cp "$REPO_DIR/nginx-synapse-hardening.conf" /etc/nginx/snippets/synapse-hardening.conf
    # Prepend include to matrix 443 server block (before location /_matrix)
    if ! grep -q synapse-hardening /etc/nginx/sites-available/matrix 2>/dev/null; then
      sed -i "/location \/_matrix {/i\    include /etc/nginx/snippets/synapse-hardening.conf;" /etc/nginx/sites-available/matrix
    fi
    nginx -t && svc_reload nginx
  fi
  echo "  Fail2ban and nginx hardening applied."
}

# ========== Phase 11: Backup script + cron ==========
setup_backup() {
  echo "[11/14] Backup script and cron..."
  if [ "$INSTALL_BACKUP_CRON" != "y" ]; then return 0; fi
  mkdir -p /opt/matrix-backup
  # Copy whole repo so backup and future deploys have all configs
  if [ -d "$REPO_DIR" ] && [ -f "$REPO_DIR/backup-matrix.sh" ]; then
    cp -a "$REPO_DIR"/* /opt/matrix-backup/ 2>/dev/null || true
    [ -d "$REPO_DIR/grafana" ] && cp -a "$REPO_DIR/grafana" /opt/matrix-backup/ 2>/dev/null || true
    [ -d "$REPO_DIR/fail2ban-matrix" ] && cp -a "$REPO_DIR/fail2ban-matrix" /opt/matrix-backup/ 2>/dev/null || true
    [ -d "$REPO_DIR/well-known" ] && cp -a "$REPO_DIR/well-known" /opt/matrix-backup/ 2>/dev/null || true
    chmod +x /opt/matrix-backup/backup-matrix.sh 2>/dev/null || true
  fi
  # Cron daily at 03:00
  (crontab -l 2>/dev/null | grep -v "backup-matrix.sh"; echo "0 3 * * * /opt/matrix-backup/backup-matrix.sh") | crontab -
  mkdir -p /var/backups/matrix
  echo "  Backup script at /opt/matrix-backup/backup-matrix.sh; cron daily at 03:00."
}

# ========== Phase 12: Mjolnir (moderation bot, Docker) ==========
setup_mjolnir() {
  echo "[12/14] Mjolnir (moderation bot)..."
  if [ "$INSTALL_MJOLNIR" != "y" ]; then return 0; fi
  if ! command -v docker &>/dev/null; then
    echo "  Docker not installed; skipping Mjolnir. Install Docker and run setup-mjolnir.sh from this repo."
    return 0
  fi
  # Require admin password to create @mjolnir user and get token
  echo "  Mjolnir needs an existing admin to create the bot user. Enter admin localpart (e.g. $ADMIN_USER) and password when prompted."
  read -p "Admin localpart for Mjolnir setup [$ADMIN_USER]: " MJOLNIR_ADMIN
  MJOLNIR_ADMIN="${MJOLNIR_ADMIN:-$ADMIN_USER}"
  read -sp "Admin password: " ADMIN_PASSWORD
  echo ""
  if [ -z "$ADMIN_PASSWORD" ]; then
    echo "  No password provided; skipping Mjolnir. Run $REPO_DIR/setup-mjolnir.sh manually (set MATRIX_PASSWORD, BASE=https://$MATRIX_DOMAIN, SERVER_NAME=$SERVER_NAME)."
    return 0
  fi
  BASE="https://$MATRIX_DOMAIN"
  ADMIN_TOKEN=$(curl -sS -X POST "$BASE/_matrix/client/r0/login" -H "Content-Type: application/json" \
    -d "{\"type\":\"m.login.password\",\"user\":\"$MJOLNIR_ADMIN\",\"password\":\"$ADMIN_PASSWORD\"}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
  if [ -z "$ADMIN_TOKEN" ]; then
    echo "  Failed to get admin token; skipping Mjolnir. Run setup-mjolnir.sh manually."
    return 0
  fi
  MJOLNIR_PASSWORD="${MJOLNIR_PASSWORD:-$(openssl rand -base64 24)}"
  curl -sS -X PUT "$BASE/_synapse/admin/v2/users/@mjolnir:$SERVER_NAME" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
    -d "{\"password\":\"$MJOLNIR_PASSWORD\",\"admin\":true,\"logout_devices\":false}" | grep -q "name" || true
  MJOLNIR_TOKEN=$(curl -sS -X POST "$BASE/_matrix/client/r0/login" -H "Content-Type: application/json" \
    -d "{\"type\":\"m.login.password\",\"user\":\"mjolnir\",\"password\":\"$MJOLNIR_PASSWORD\"}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
  if [ -z "$MJOLNIR_TOKEN" ]; then
    echo "  Failed to get Mjolnir token (rate limit?); run setup-mjolnir.sh later with MJOLNIR_PASSWORD=$MJOLNIR_PASSWORD"
    return 0
  fi
  ROOM_ID=$(curl -sS -X POST "$BASE/_matrix/client/r0/createRoom" -H "Authorization: Bearer $MJOLNIR_TOKEN" \
    -H "Content-Type: application/json" -d '{"name":"Mjolnir management","preset":"private_chat"}' | python3 -c "import sys,json; print(json.load(sys.stdin).get('room_id',''))" 2>/dev/null)
  if [ -z "$ROOM_ID" ]; then
    echo "  Failed to create management room; run setup-mjolnir.sh manually."
    return 0
  fi
  # Invite admin to management room
  curl -sS -X POST "$BASE/_matrix/client/r0/rooms/${ROOM_ID}/invite" -H "Authorization: Bearer $MJOLNIR_TOKEN" \
    -H "Content-Type: application/json" -d "{\"user_id\":\"@$MJOLNIR_ADMIN:$SERVER_NAME\"}" >/dev/null 2>&1 || true
  mkdir -p /opt/mjolnir/config /opt/mjolnir/data
  if [ -f "$REPO_DIR/mjolnir-production.yaml" ]; then
    sed "s|https://matrix.example.com|$BASE|g;s|example.com|$SERVER_NAME|g;s|REPLACE_AFTER_SETUP|$MJOLNIR_TOKEN|g;s|!REPLACE:example.com|$ROOM_ID|g" "$REPO_DIR/mjolnir-production.yaml" > /opt/mjolnir/config/production.yaml
  else
    cat > /opt/mjolnir/config/production.yaml << EOF
homeserverUrl: $BASE
rawHomeserverUrl: $BASE
accessToken: $MJOLNIR_TOKEN
managementRoom: "$ROOM_ID"
encryption:
  use: false
dataPath: /opt/mjolnir/data
autojoinOnlyIfManager: true
logLevel: INFO
EOF
  fi
  # Run Mjolnir via Docker (official image)
  if ! docker image inspect matrixdotorg/mjolnir &>/dev/null 2>&1; then
    docker pull matrixdotorg/mjolnir:latest
  fi
  (docker stop mjolnir 2>/dev/null; docker rm mjolnir 2>/dev/null) || true
  docker run -d --name mjolnir --restart unless-stopped \
    -v /opt/mjolnir/config/production.yaml:/config/production.yaml:ro \
    -v /opt/mjolnir/data:/data \
    matrixdotorg/mjolnir:latest \
    /usr/bin/node lib/index.js -c /config/production.yaml
  echo "  Mjolnir running (Docker container mjolnir). Management room: $ROOM_ID (invited @$MJOLNIR_ADMIN:$SERVER_NAME)."
}

# ========== Phase 13: Maubot (plugin bot) ==========
setup_maubot() {
  echo "[13/14] Maubot..."
  if [ "$INSTALL_MAUBOT" != "y" ]; then return 0; fi
  echo "  Maubot needs an admin to create @maubot user. Enter admin localpart and password if you want script to create the user now."
  read -p "Create @maubot:$SERVER_NAME now? (y/n) [y]: " do_maubot
  do_maubot="${do_maubot:-y}"
  if [[ ! "$do_maubot" =~ ^[yY] ]]; then
    echo "  Skipping Maubot user. Run $REPO_DIR/setup-maubot-user.sh later (set BASE=https://$MATRIX_DOMAIN)."
    return 0
  fi
  read -p "Admin localpart [$ADMIN_USER]: " MAUBOT_ADMIN
  MAUBOT_ADMIN="${MAUBOT_ADMIN:-$ADMIN_USER}"
  read -sp "Admin password: " ADMIN_PASSWORD
  echo ""
  if [ -z "$ADMIN_PASSWORD" ]; then
    echo "  No password; run setup-maubot-user.sh manually."
    return 0
  fi
  BASE="https://$MATRIX_DOMAIN"
  ADMIN_TOKEN=$(curl -sS -X POST "$BASE/_matrix/client/r0/login" -H "Content-Type: application/json" \
    -d "{\"type\":\"m.login.password\",\"user\":\"$MAUBOT_ADMIN\",\"password\":\"$ADMIN_PASSWORD\"}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
  if [ -z "$ADMIN_TOKEN" ]; then
    echo "  Failed to get admin token; run setup-maubot-user.sh manually."
    return 0
  fi
  MAUBOT_PW="${MAUBOT_PASSWORD:-$(openssl rand -hex 8)}"
  curl -sS -X PUT "$BASE/_synapse/admin/v2/users/@maubot:$SERVER_NAME" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
    -d "{\"password\":\"$MAUBOT_PW\",\"admin\":false,\"logout_devices\":false}" | grep -q "name" || true
  mkdir -p /opt/maubot
  if [ -f "$REPO_DIR/maubot-patch.yaml" ]; then
    sed "s|https://matrix.example.com|$BASE|g;s|example.com|$SERVER_NAME|g" "$REPO_DIR/maubot-patch.yaml" > /opt/maubot/config.yaml
  else
    cat > /opt/maubot/config.yaml << EOF
homeservers:
  $SERVER_NAME:
    url: $BASE
    secret: null
server:
  public_url: $BASE
EOF
  fi
  echo "  @maubot:$SERVER_NAME created. Password for maubot UI: $MAUBOT_PW"
  echo "  Install Maubot (pip install maubot) and run: mbc run -c /opt/maubot/config.yaml. Or use Docker: see Maubot docs."
}

# ========== Phase 14: Discord bridge ==========
setup_discord() {
  echo "[14/14] Discord bridge..."
  if [ "$INSTALL_DISCORD" != "y" ]; then return 0; fi
  read -p "Discord bot token (from Discord Developer Portal; or leave empty to add later): " DISCORD_BOT_TOKEN
  mkdir -p /opt/discord-bridge
  if [ -f "$REPO_DIR/discord-bridge-config.yaml" ]; then
    sed "s|example.com|$SERVER_NAME|g;s|https://matrix.example.com|https://$MATRIX_DOMAIN|g" "$REPO_DIR/discord-bridge-config.yaml" > /opt/discord-bridge/config.yaml
    if [ -n "$DISCORD_BOT_TOKEN" ]; then
      sed -i "s|YOUR_DISCORD_BOT_TOKEN|$DISCORD_BOT_TOKEN|g" /opt/discord-bridge/config.yaml
    fi
    # Prompt for admin MXID for bridge
    read -p "Bridge admin MXID [@$ADMIN_USER:$SERVER_NAME]: " BRIDGE_ADMIN
    BRIDGE_ADMIN="${BRIDGE_ADMIN:-@$ADMIN_USER:$SERVER_NAME}"
    # Replace placeholder admin MXID (after first sed it's @admin:SERVER_NAME) with chosen BRIDGE_ADMIN
sed -i "s|@admin:$SERVER_NAME|$BRIDGE_ADMIN|g" /opt/discord-bridge/config.yaml
  fi
  # Generate registration: run matrix-appservice-discord in registration mode (requires Node or Docker)
  if command -v npx &>/dev/null; then
    (cd /opt/discord-bridge && npx -y matrix-appservice-discord -r -u "http://localhost:9005" -c config.yaml 2>/dev/null | head -n 200 > discord-registration.yaml) || true
  fi
  if [ -f /opt/discord-bridge/discord-registration.yaml ] && [ -s /opt/discord-bridge/discord-registration.yaml ]; then
    cp /opt/discord-bridge/discord-registration.yaml /etc/matrix-synapse/discord-registration.yaml
    if [ -f "$REPO_DIR/synapse-appservice-discord.yaml" ]; then
      cp "$REPO_DIR/synapse-appservice-discord.yaml" /etc/matrix-synapse/conf.d/50-appservice-discord.yaml
      # Ensure path in conf points to the registration file
      sed -i "s|/etc/matrix-synapse/discord-registration.yaml|/etc/matrix-synapse/discord-registration.yaml|g" /etc/matrix-synapse/conf.d/50-appservice-discord.yaml
    else
      echo "app_service_config_files:" > /etc/matrix-synapse/conf.d/50-appservice-discord.yaml
      echo "  - /etc/matrix-synapse/discord-registration.yaml" >> /etc/matrix-synapse/conf.d/50-appservice-discord.yaml
    fi
    chown matrix-synapse:matrix-synapse /etc/matrix-synapse/conf.d/50-appservice-discord.yaml /etc/matrix-synapse/discord-registration.yaml
    svc_restart matrix-synapse
    echo "  Discord bridge registration added to Synapse. Start the bridge: cd /opt/discord-bridge && node index.js (or use Docker)."
  else
    echo "  Could not generate Discord registration (npx not found or bridge failed). Create Discord app, get bot token, then run: npx matrix-appservice-discord -r -u http://localhost:9005 -c /opt/discord-bridge/config.yaml and copy output to /etc/matrix-synapse/discord-registration.yaml, add app_service_config_files to Synapse conf.d, restart Synapse."
  fi
}

# ========== Create first user ==========
create_admin_user() {
  echo ""
  if [ "${NON_INTERACTIVE:-0}" = "1" ]; then
    if [ -n "$ADMIN_PASSWORD" ]; then
      echo "  Creating admin user @${ADMIN_USER}:$SERVER_NAME (NON_INTERACTIVE)..."
      (echo "$ADMIN_PASSWORD"; echo "$ADMIN_PASSWORD") | register_new_matrix_user -c /etc/matrix-synapse/homeserver.yaml http://localhost:8008 -u "$ADMIN_USER" -p -a 2>/dev/null || true
      [ $? -eq 0 ] && echo "  Admin created." || echo "  Run manually: register_new_matrix_user -c /etc/matrix-synapse/homeserver.yaml http://localhost:8008 -u $ADMIN_USER -p -a"
    else
      echo "  Skipping admin user (set ADMIN_PASSWORD to create in non-interactive mode). Run: register_new_matrix_user -c /etc/matrix-synapse/homeserver.yaml http://localhost:8008 -u $ADMIN_USER -p -a"
    fi
    return 0
  fi
  read -p "Create first admin user @${ADMIN_USER}:$SERVER_NAME now? (y/n) [y]: " do_user
  do_user="${do_user:-y}"
  if [[ "$do_user" =~ ^[yY] ]]; then
    echo "  (Password will be prompted; use shared-secret from config.)"
    register_new_matrix_user -c /etc/matrix-synapse/homeserver.yaml http://localhost:8008 -u "$ADMIN_USER" -p -a 2>/dev/null || true
    if [ $? -eq 0 ]; then
      echo "  Admin created. You can remove registration_shared_secret from /etc/matrix-synapse/conf.d/registration.yaml later for extra lock-down."
    else
      echo "  Run manually: register_new_matrix_user -c /etc/matrix-synapse/homeserver.yaml http://localhost:8008 -u $ADMIN_USER -p -a"
    fi
  fi
}

# ========== Main ==========
main() {
  run_prompts
  install_base
  install_synapse
  setup_postgres
  setup_synapse_config
  setup_nginx_tls
  setup_coturn
  setup_monitoring
  setup_metrics_auth
  setup_element_call
  setup_fail2ban_nginx_hardening
  setup_backup
  setup_mjolnir
  setup_maubot
  setup_discord
  create_admin_user

  echo ""
  echo "=== Setup complete ==="
  echo "  Matrix client URL: https://$MATRIX_DOMAIN"
  echo "  Server name (MXID): $SERVER_NAME"
  echo "  First admin: @${ADMIN_USER}:$SERVER_NAME"
  echo "  DB password (store securely): in /etc/matrix-synapse/conf.d/database.yaml"
  echo "  TURN secret: /root/.matrix-turn-secret (if coturn installed)"
  echo "  Registration shared secret: in conf.d/registration.yaml (remove after creating first user if desired)"
  echo "  Backup: /opt/matrix-backup/backup-matrix.sh (cron 03:00)"
  [ "$INSTALL_MONITORING" = "y" ] && [ "$INSTALL_METRICS_AUTH" = "y" ] && echo "  Gated metrics: https://$MATRIX_DOMAIN/metrics/ (login with Matrix)"
  [ "$INSTALL_ELEMENT_CALL" = "y" ] && echo "  Element Call backend: /opt/element-call (LiveKit + lk-jwt-service)"
  [ "$INSTALL_MJOLNIR" = "y" ] && echo "  Mjolnir: Docker container mjolnir"
  echo ""
  echo "Next: Install Element Web (or use element.io) and set homeserver to https://$MATRIX_DOMAIN. See README for post-setup steps."
}

main "$@"
