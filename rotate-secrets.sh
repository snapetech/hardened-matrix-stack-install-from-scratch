#!/bin/bash
# Emergency secret rotation. Run after backup-keys-pre-rotation.sh.
# Usage: sudo ./rotate-secrets.sh --dry-run   # print plan, no changes
#        sudo ./rotate-secrets.sh --execute   # perform rotation (Phases A–G automated when env set)
# Env: MATRIX_DOMAIN, ROOT_DOMAIN (required). SERVER_NAME (default ROOT_DOMAIN, for MXIDs).
#      ADMIN_ACCESS_TOKEN = Synapse admin token (enables Phase E–F). If unset: try keyring (service
#        matrix-admin user $MATRIX_DOMAIN), then create a temp admin via registration_shared_secret,
#        use for E–F, then deactivate the temp user. No manual token needed when run on server.
#      DISCORD_NEW_BOT_TOKEN = new Discord bot token from Portal (enables Phase G).
set -e

DRY_RUN=1
# Allow env trigger so "ROTATE_EXECUTE=1 script" works when args can't be passed (e.g. over ssh pipe)
[ -n "${ROTATE_EXECUTE:-}" ] && DRY_RUN=0
for arg in "$@"; do
  [ "$arg" = "--dry-run" ] && DRY_RUN=1
  [ "$arg" = "--execute" ] && DRY_RUN=0
done

MATRIX_DOMAIN="${MATRIX_DOMAIN:?Set MATRIX_DOMAIN}"
ROOT_DOMAIN="${ROOT_DOMAIN:-$MATRIX_DOMAIN}"
SERVER_NAME="${SERVER_NAME:-$ROOT_DOMAIN}"
KEYS_BACKUP_ROOT="${KEYS_BACKUP_ROOT:-/var/backups/matrix-keys-pre-rotation}"
SYNAPSE_INTERNAL="${SYNAPSE_INTERNAL:-http://127.0.0.1:8008}"

# Retrieve admin token: keyring first, then temp admin via registration_shared_secret (so E–F are fully automated on server)
ADMIN_ACCESS_TOKEN="${ADMIN_ACCESS_TOKEN:-$(secret-tool lookup service matrix-admin user "$MATRIX_DOMAIN" 2>/dev/null)}" || true
ROTATION_CREATED_TEMP_ADMIN=0
TEMP_ADMIN_USER=""
CERTBOT_PHASE_A_FAILED=0

need_admin_for_ef() {
  [ -f /opt/draupnir/config/production.yaml ] || [ -f /opt/mjolnir/config/production.yaml ] || [ -f /opt/maubot/config.yaml ]
}

run_cmd() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] would run: $*"
  else
    "$@"
  fi
}

echo_sep() { echo ""; echo "=== $* ==="; }

# Check backup exists (required for execute)
if [ "$DRY_RUN" = "1" ]; then
  if [ -d "$KEYS_BACKUP_ROOT" ] && [ -n "$(ls -A "$KEYS_BACKUP_ROOT" 2>/dev/null)" ]; then
    echo "[dry-run] backup dir exists: $KEYS_BACKUP_ROOT (latest would be used for rollback)"
  else
    echo "[dry-run] WARN: no backup found at $KEYS_BACKUP_ROOT; run backup-keys-pre-rotation.sh first"
  fi
else
  if [ ! -d "$KEYS_BACKUP_ROOT" ] || [ -z "$(ls -A "$KEYS_BACKUP_ROOT" 2>/dev/null)" ]; then
    echo "Error: no backup at $KEYS_BACKUP_ROOT. Run backup-keys-pre-rotation.sh first." >&2
    exit 1
  fi
  echo "Using backup root: $KEYS_BACKUP_ROOT"
fi

if [ "$DRY_RUN" = "1" ] && need_admin_for_ef; then
  echo "[dry-run] would obtain admin token (keyring or temp user via registration_shared_secret) for Phase E–F"
fi

# Resolve register_new_matrix_user (Debian puts it in /usr/bin; root over ssh may have minimal PATH)
if [ -x /usr/bin/register_new_matrix_user ]; then
  REGISTER_CMD=/usr/bin/register_new_matrix_user
elif command -v register_new_matrix_user &>/dev/null; then
  REGISTER_CMD=register_new_matrix_user
else
  REGISTER_CMD=register_new_matrix_user
fi

# Obtain admin token for E–F if not set: create temp admin via registration_shared_secret (before Phase B rotates it)
if [ "$DRY_RUN" = "0" ] && [ -z "${ADMIN_ACCESS_TOKEN:-}" ] && need_admin_for_ef; then
  echo "  Creating temp admin for Phase E–F (registration_shared_secret)..."
  CURRENT_REG_SECRET=""
  if [ -f /etc/matrix-synapse/conf.d/registration.yaml ]; then
    CURRENT_REG_SECRET=$(grep 'registration_shared_secret' /etc/matrix-synapse/conf.d/registration.yaml | sed 's/.*: *//; s/^["'\'']//; s/["\x27].*//; s/[[:space:]].*//; q')
  fi
  if [ -z "$CURRENT_REG_SECRET" ]; then
    echo "  No registration_shared_secret in conf.d/registration.yaml; cannot create temp admin. Phase E–F skipped." >&2
  else
    TEMP_ADMIN_USER="rotation_$(openssl rand -hex 4)"
    TEMP_ADMIN_PASS=$(openssl rand -hex 24)
    REG_ERR=$(mktemp)
    trap "rm -f $REG_ERR" EXIT
    if $REGISTER_CMD -k "$CURRENT_REG_SECRET" http://localhost:8008 -u "$TEMP_ADMIN_USER" -p "$TEMP_ADMIN_PASS" -a 2>"$REG_ERR"; then
    # Login: try localpart first; some Synapse versions want user_id
    BODY=$(printf '{"type":"m.login.password","user":"%s","password":"%s"}' "$TEMP_ADMIN_USER" "$TEMP_ADMIN_PASS")
    ADMIN_ACCESS_TOKEN=$(curl -sS -X POST "$SYNAPSE_INTERNAL/_matrix/client/r0/login" \
      -H "Host: $MATRIX_DOMAIN" -H "Content-Type: application/json" \
      -d "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null)
    if [ -z "${ADMIN_ACCESS_TOKEN:-}" ]; then
      BODY=$(printf '{"type":"m.login.password","user":"@%s:%s","password":"%s"}' "$TEMP_ADMIN_USER" "$SERVER_NAME" "$TEMP_ADMIN_PASS")
      ADMIN_ACCESS_TOKEN=$(curl -sS -X POST "$SYNAPSE_INTERNAL/_matrix/client/r0/login" \
        -H "Host: $MATRIX_DOMAIN" -H "Content-Type: application/json" \
        -d "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null)
    fi
    if [ -n "${ADMIN_ACCESS_TOKEN:-}" ]; then
      ROTATION_CREATED_TEMP_ADMIN=1
      echo "  Obtained admin token via temp user @${TEMP_ADMIN_USER}:$SERVER_NAME (will deactivate after Phase F)."
    else
      echo "  Temp admin created but login failed (check Host header / Synapse). Phase E–F will be skipped." >&2
    fi
  else
      echo "  Temp admin registration failed: $(cat "$REG_ERR" 2>/dev/null | head -5)" >&2
      echo "  Phase E–F will be skipped. Install matrix-synapse-py3 or set ADMIN_ACCESS_TOKEN." >&2
    fi
    rm -f "$REG_ERR"
    trap - EXIT
  fi
fi

# ---------- Phase A: TLS (continue on certbot failure e.g. LE rate limit) ----------
echo_sep "Phase A – TLS"
if [ -d /etc/letsencrypt/live/"$MATRIX_DOMAIN" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    run_cmd certbot certonly --nginx --force-renewal -d "$MATRIX_DOMAIN" --non-interactive
  else
    certbot certonly --nginx --force-renewal -d "$MATRIX_DOMAIN" --non-interactive || { CERTBOT_PHASE_A_FAILED=1; echo "  Certbot failed (e.g. rate limit); continuing without TLS renewal."; true; }
  fi
  if [ "$DRY_RUN" = "0" ] && [ "$ROOT_DOMAIN" != "$MATRIX_DOMAIN" ] && [ -d /etc/letsencrypt/live/"$ROOT_DOMAIN" ]; then
    certbot certonly --nginx --force-renewal -d "$ROOT_DOMAIN" --non-interactive || CERTBOT_PHASE_A_FAILED=1
  fi
  [ "$ROOT_DOMAIN" != "$MATRIX_DOMAIN" ] && [ -d /etc/letsencrypt/live/"$ROOT_DOMAIN" ] && [ "$DRY_RUN" = "1" ] && run_cmd certbot certonly --nginx --force-renewal -d "$ROOT_DOMAIN" --non-interactive
  run_cmd nginx -t
  run_cmd systemctl reload nginx
else
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] no Let's Encrypt for $MATRIX_DOMAIN; would skip or regenerate self-signed"
  fi
  if [ -f /etc/nginx/ssl/matrix-selfsigned.key ]; then
    run_cmd openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/nginx/ssl/matrix-selfsigned.key -out /etc/nginx/ssl/matrix-selfsigned.crt -subj "/CN=$MATRIX_DOMAIN/O=Matrix"
    run_cmd nginx -t
    run_cmd systemctl reload nginx
  fi
fi

# ---------- Phase B: DB password + registration secret, then Synapse restart ----------
echo_sep "Phase B – Database and registration"
NEW_DB_PASS=
NEW_REG_SECRET=
if [ "$DRY_RUN" = "1" ]; then
  echo "[dry-run] would generate new DB password (openssl rand -hex 16)"
  echo "[dry-run] would generate new registration_shared_secret (openssl rand -hex 32)"
  echo "[dry-run] would run: sudo -u postgres psql -c \"ALTER USER synapse WITH PASSWORD '...';\""
  echo "[dry-run] would update /etc/matrix-synapse/conf.d/database.yaml"
  echo "[dry-run] would update /etc/matrix-synapse/conf.d/registration.yaml"
  echo "[dry-run] would chown/chmod and systemctl restart matrix-synapse"
else
  NEW_DB_PASS=$(openssl rand -hex 16)
  NEW_REG_SECRET=$(openssl rand -hex 32)
  run_cmd sudo -u postgres psql -c "ALTER USER synapse WITH PASSWORD '$NEW_DB_PASS';"
  # Update database.yaml (preserve structure, replace password line)
  sed -i "s/^[[:space:]]*password:.*/    password: $NEW_DB_PASS/" /etc/matrix-synapse/conf.d/database.yaml
  sed -i "s/registration_shared_secret:.*/registration_shared_secret: \"$NEW_REG_SECRET\"/" /etc/matrix-synapse/conf.d/registration.yaml
  chown matrix-synapse:matrix-synapse /etc/matrix-synapse/conf.d/database.yaml /etc/matrix-synapse/conf.d/registration.yaml
  chmod 600 /etc/matrix-synapse/conf.d/database.yaml /etc/matrix-synapse/conf.d/registration.yaml
  # Synapse restart deferred to after Phase C (one restart)
fi

# ---------- Phase C: TURN secret ----------
echo_sep "Phase C – TURN"
NEW_TURN=
if [ "$DRY_RUN" = "1" ]; then
  echo "[dry-run] would generate new TURN secret (openssl rand -hex 32)"
  echo "[dry-run] would write /root/.matrix-turn-secret"
  echo "[dry-run] would update /etc/matrix-synapse/conf.d/turn.yaml"
  echo "[dry-run] would sed static-auth-secret in /etc/turnserver.conf"
  echo "[dry-run] would systemctl restart coturn"
  echo "[dry-run] would systemctl restart matrix-synapse (single restart after B+C)"
else
  NEW_TURN=$(openssl rand -hex 32)
  echo -n "$NEW_TURN" > /root/.matrix-turn-secret
  chmod 600 /root/.matrix-turn-secret
  # turn.yaml
  cat > /etc/matrix-synapse/conf.d/turn.yaml << EOF
turn_uris:
  - "turn:$MATRIX_DOMAIN:3478?transport=udp"
  - "turn:$MATRIX_DOMAIN:3478?transport=tcp"
turn_shared_secret: "$NEW_TURN"
turn_user_lifetime: 86400000
turn_allow_guests: false
EOF
  chown matrix-synapse:matrix-synapse /etc/matrix-synapse/conf.d/turn.yaml
  # turnserver.conf: replace static-auth-secret line (matrix-setup block)
  if grep -q "static-auth-secret" /etc/turnserver.conf; then
    sed -i "s/^static-auth-secret=.*/static-auth-secret=$NEW_TURN/" /etc/turnserver.conf
  fi
  run_cmd systemctl restart coturn
  run_cmd systemctl restart matrix-synapse
fi

# ---------- Phase D: LiveKit ----------
echo_sep "Phase D – Element Call / LiveKit"
if [ -f /opt/element-call/.env ] || [ -f /opt/element-call/livekit.yaml ]; then
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] would generate new LIVEKIT_KEY and LIVEKIT_SECRET"
    echo "[dry-run] would update /opt/element-call/livekit.yaml and .env"
    echo "[dry-run] would cd /opt/element-call && docker compose down && docker compose up -d"
  else
    NEW_LK_KEY=$(openssl rand -hex 16)
    NEW_LK_SECRET=$(openssl rand -base64 32)
    # livekit.yaml: replace keys block (single key line)
    if [ -f /opt/element-call/livekit.yaml ]; then
      # Replace the key line under "keys:" (  hex: "secret" ); use | delimiter so secret can contain /
      sed -i "s|^[[:space:]]*[a-f0-9]*:[[:space:]]*\"[^\"]*\"|  $NEW_LK_KEY: \"$NEW_LK_SECRET\"|" /opt/element-call/livekit.yaml 2>/dev/null || true
    fi
    if [ -f /opt/element-call/.env ]; then
      sed -i "s|^LIVEKIT_KEY=.*|LIVEKIT_KEY=$NEW_LK_KEY|" /opt/element-call/.env
      sed -i "s|^LIVEKIT_SECRET=.*|LIVEKIT_SECRET=$NEW_LK_SECRET|" /opt/element-call/.env
    fi
    (cd /opt/element-call && run_cmd docker compose down) 2>/dev/null || (cd /opt/element-call && run_cmd docker-compose down) 2>/dev/null || true
    (cd /opt/element-call && run_cmd docker compose up -d) 2>/dev/null || (cd /opt/element-call && run_cmd docker-compose up -d) 2>/dev/null || true
  fi
else
  echo "Phase D: no Element Call config; skipping"
fi

# ---------- Phase E: Draupnir + Mjolnir (need ADMIN_ACCESS_TOKEN) ----------
echo_sep "Phase E – Draupnir and Mjolnir"
if [ -n "${ADMIN_ACCESS_TOKEN:-}" ]; then
  for BOT in draupnir mjolnir; do
    [ ! -f /opt/$BOT/config/production.yaml ] && continue
    if [ "$DRY_RUN" = "1" ]; then
      echo "[dry-run] would reset @$BOT:$SERVER_NAME password, login, update /opt/$BOT/config/production.yaml, docker restart $BOT"
    else
      BOT_PASS=$(openssl rand -base64 24)
      curl -sS -X PUT "$SYNAPSE_INTERNAL/_synapse/admin/v2/users/@${BOT}:$SERVER_NAME" \
        -H "Authorization: Bearer $ADMIN_ACCESS_TOKEN" -H "Content-Type: application/json" \
        -d "{\"password\":\"$BOT_PASS\"}" | grep -q "name" || true
      BOT_TOKEN=$(curl -sS -X POST "$SYNAPSE_INTERNAL/_matrix/client/r0/login" \
        -H "Host: $MATRIX_DOMAIN" -H "Content-Type: application/json" \
        -d "{\"type\":\"m.login.password\",\"user\":\"$BOT\",\"password\":\"$BOT_PASS\"}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
      if [ -n "$BOT_TOKEN" ]; then
        sed -i "s|accessToken:.*|accessToken: \"$BOT_TOKEN\"|" /opt/$BOT/config/production.yaml
        run_cmd docker restart $BOT
      fi
    fi
  done
else
  echo "Phase E: ADMIN_ACCESS_TOKEN not set; skipping Draupnir/Mjolnir token rotation"
fi

# ---------- Phase F: Maubot (need ADMIN_ACCESS_TOKEN) ----------
echo_sep "Phase F – Maubot"
if [ -n "${ADMIN_ACCESS_TOKEN:-}" ] && [ -f /opt/maubot/config.yaml ]; then
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] would reset @maubot:$SERVER_NAME password and update /opt/maubot/config.yaml if password/url present"
  else
    MAUBOT_PASS=$(openssl rand -hex 12)
    curl -sS -X PUT "$SYNAPSE_INTERNAL/_synapse/admin/v2/users/@maubot:$SERVER_NAME" \
      -H "Authorization: Bearer $ADMIN_ACCESS_TOKEN" -H "Content-Type: application/json" \
      -d "{\"password\":\"$MAUBOT_PASS\"}" | grep -q "name" || true
    if grep -q "password:" /opt/maubot/config.yaml 2>/dev/null; then
      sed -i "s|password:.*|password: \"$MAUBOT_PASS\"|" /opt/maubot/config.yaml 2>/dev/null || true
    fi
    echo "  Maubot new password (store it): $MAUBOT_PASS"
  fi
else
  [ -f /opt/maubot/config.yaml ] && echo "Phase F: ADMIN_ACCESS_TOKEN not set; skipping Maubot"
fi

# Deactivate temp admin if we created one (token no longer valid after this)
if [ "$DRY_RUN" = "0" ] && [ "$ROTATION_CREATED_TEMP_ADMIN" = "1" ] && [ -n "$TEMP_ADMIN_USER" ]; then
  USER_ID="@${TEMP_ADMIN_USER}:$SERVER_NAME"
  USER_ID_ENC=$(echo -n "$USER_ID" | sed 's/@/%40/g; s/:/%3A/g')
  curl -sS -X PUT "$SYNAPSE_INTERNAL/_synapse/admin/v2/users/$USER_ID_ENC" \
    -H "Authorization: Bearer $ADMIN_ACCESS_TOKEN" -H "Content-Type: application/json" \
    -d '{"deactivated":true}' 2>/dev/null || true
  echo "  Deactivated temp user $USER_ID"
fi

# ---------- Phase G: Discord (need DISCORD_NEW_BOT_TOKEN) ----------
echo_sep "Phase G – Discord bridge"
if [ -n "${DISCORD_NEW_BOT_TOKEN:-}" ] && [ -f /opt/discord-bridge/config.yaml ]; then
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] would update auth.botToken, regenerate registration, replace in Synapse, restart Synapse and bridge"
  else
    set +e
    err=0
    sed -i "s|  botToken:.*|  botToken: \"$DISCORD_NEW_BOT_TOKEN\"|" /opt/discord-bridge/config.yaml || err=1
    (cd /opt/discord-bridge && npx -y matrix-appservice-discord -r -u "http://localhost:9005" -c config.yaml 2>/dev/null) > /tmp/discord-registration-new.yaml || err=1
    if [ -s /tmp/discord-registration-new.yaml ]; then
      cp /tmp/discord-registration-new.yaml /etc/matrix-synapse/discord-registration.yaml || err=1
      chown matrix-synapse:matrix-synapse /etc/matrix-synapse/discord-registration.yaml 2>/dev/null || true
      [ $err -eq 0 ] && run_cmd systemctl restart matrix-synapse
      cp /tmp/discord-registration-new.yaml /opt/discord-bridge/discord-registration.yaml 2>/dev/null || true
    else
      err=1
    fi
    rm -f /tmp/discord-registration-new.yaml
    docker restart discord-bridge 2>/dev/null || true
    pkill -f matrix-appservice-discord 2>/dev/null || true
    set -e
    if [ $err -ne 0 ]; then
      echo "Phase G: Discord bridge not fully set up (npx/registration failed); skipped rest. Fix and re-run if needed." >&2
    fi
  fi
else
  if [ ! -f /opt/discord-bridge/config.yaml ]; then
    echo "Phase G: Discord not set up (no config); skipping"
  else
    echo "Phase G: DISCORD_NEW_BOT_TOKEN not set; skipping Discord"
  fi
fi

if [ "$DRY_RUN" = "1" ]; then
  echo ""
  echo "=== Rotation dry-run complete. No changes were made. ==="
else
  echo ""
  if [ "$CERTBOT_PHASE_A_FAILED" = "1" ]; then
    echo "" >&2
    echo "*** ALERT: Phase A (TLS) was skipped due to Certbot/Let's Encrypt failure. ***" >&2
    echo "*** Common cause: rate limit (e.g. too many certificates in 7 days). ***" >&2
    echo "*** Current certs are unchanged. Check: certbot certificates" >&2
    echo "*** Retry after the rate window (see LE email or certbot output). ***" >&2
    echo "" >&2
  fi
  echo "=== Rotation complete (Phases A–G where enabled). ==="
fi
