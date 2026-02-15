#!/bin/bash
# Emergency secret rotation. Run after backup-keys-pre-rotation.sh.
# Usage: sudo ./rotate-secrets.sh --dry-run   # print plan, no changes
#        sudo ./rotate-secrets.sh --execute   # perform rotation (Phases A–G automated when env set)
# Env: MATRIX_DOMAIN, ROOT_DOMAIN (required). SERVER_NAME (default ROOT_DOMAIN, for MXIDs).
#      ADMIN_ACCESS_TOKEN = Synapse admin token (enables Phase E–F: Draupnir, Mjolnir, Maubot).
#      DISCORD_NEW_BOT_TOKEN = new Discord bot token from Portal (enables Phase G).
set -e

DRY_RUN=1
for arg in "$@"; do
  [ "$arg" = "--dry-run" ] && DRY_RUN=1
  [ "$arg" = "--execute" ] && DRY_RUN=0
done

MATRIX_DOMAIN="${MATRIX_DOMAIN:?Set MATRIX_DOMAIN}"
ROOT_DOMAIN="${ROOT_DOMAIN:-$MATRIX_DOMAIN}"
SERVER_NAME="${SERVER_NAME:-$ROOT_DOMAIN}"
KEYS_BACKUP_ROOT="${KEYS_BACKUP_ROOT:-/var/backups/matrix-keys-pre-rotation}"
SYNAPSE_INTERNAL="${SYNAPSE_INTERNAL:-http://127.0.0.1:8008}"

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

# ---------- Phase A: TLS ----------
echo_sep "Phase A – TLS"
if [ -d /etc/letsencrypt/live/"$MATRIX_DOMAIN" ]; then
  run_cmd certbot certonly --nginx --force-renewal -d "$MATRIX_DOMAIN" --non-interactive
  [ "$ROOT_DOMAIN" != "$MATRIX_DOMAIN" ] && [ -d /etc/letsencrypt/live/"$ROOT_DOMAIN" ] && run_cmd certbot certonly --nginx --force-renewal -d "$ROOT_DOMAIN" --non-interactive
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

# ---------- Phase G: Discord (need DISCORD_NEW_BOT_TOKEN) ----------
echo_sep "Phase G – Discord bridge"
if [ -n "${DISCORD_NEW_BOT_TOKEN:-}" ] && [ -f /opt/discord-bridge/config.yaml ]; then
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] would update auth.botToken, regenerate registration, replace in Synapse, restart Synapse and bridge"
  else
    sed -i "s|  botToken:.*|  botToken: \"$DISCORD_NEW_BOT_TOKEN\"|" /opt/discord-bridge/config.yaml
    (cd /opt/discord-bridge && npx -y matrix-appservice-discord -r -u "http://localhost:9005" -c config.yaml 2>/dev/null) > /tmp/discord-registration-new.yaml || true
    if [ -s /tmp/discord-registration-new.yaml ]; then
      cp /tmp/discord-registration-new.yaml /etc/matrix-synapse/discord-registration.yaml
      chown matrix-synapse:matrix-synapse /etc/matrix-synapse/discord-registration.yaml
      run_cmd systemctl restart matrix-synapse
      cp /tmp/discord-registration-new.yaml /opt/discord-bridge/discord-registration.yaml 2>/dev/null || true
    fi
    docker restart discord-bridge 2>/dev/null || true
    pkill -f matrix-appservice-discord 2>/dev/null || true
    rm -f /tmp/discord-registration-new.yaml
  fi
else
  echo "Phase G: DISCORD_NEW_BOT_TOKEN not set or no bridge config; skipping Discord"
fi

if [ "$DRY_RUN" = "1" ]; then
  echo ""
  echo "=== Rotation dry-run complete. No changes were made. ==="
else
  echo ""
  echo "=== Rotation complete (Phases A–G where enabled). ==="
fi
