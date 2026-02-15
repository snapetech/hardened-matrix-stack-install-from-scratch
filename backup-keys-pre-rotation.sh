#!/bin/bash
# Back up all keys and secrets before rotation (re-runnable).
# Usage: sudo ./backup-keys-pre-rotation.sh [--dry-run]
#   --dry-run: print what would be copied; do not create dir or write files.
# Env: KEYS_BACKUP_ROOT (default /var/backups/matrix-keys-pre-rotation),
#      MATRIX_DOMAIN, ROOT_DOMAIN for Let's Encrypt paths.
set -e

DRY_RUN=0
for arg in "$@"; do
  [ "$arg" = "--dry-run" ] && DRY_RUN=1
done

KEYS_BACKUP_ROOT="${KEYS_BACKUP_ROOT:-/var/backups/matrix-keys-pre-rotation}"
STAMP=$(date +%Y%m%d-%H%M%S)
DEST="$KEYS_BACKUP_ROOT/$STAMP"
MATRIX_DOMAIN="${MATRIX_DOMAIN:-matrix.example.com}"
ROOT_DOMAIN="${ROOT_DOMAIN:-$MATRIX_DOMAIN}"

echo_action() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] would: $*"
  else
    echo "$*"
  fi
}

do_copy() {
  local src="$1"
  local dest="$2"
  if [ ! -e "$src" ]; then return 0; fi
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] copy $src -> $dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  cp -a "$src" "$dest" 2>/dev/null || true
}

do_copy_follow() {
  local src="$1"
  local dest="$2"
  if [ ! -e "$src" ]; then return 0; fi
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] copy -L $src -> $dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  cp -L "$src" "$dest" 2>/dev/null || true
}

if [ "$DRY_RUN" = "1" ]; then
  echo "=== Dry run: no files will be written ==="
  echo "DEST would be: $DEST"
  echo ""
else
  umask 077
  mkdir -p "$DEST"
  chmod 700 "$DEST"
fi

# Synapse
do_copy /etc/matrix-synapse/homeserver.signing.key "$DEST/homeserver.signing.key"
if [ -d /etc/matrix-synapse/conf.d ]; then
  for f in /etc/matrix-synapse/conf.d/*.yaml; do
    [ -f "$f" ] || continue
    do_copy "$f" "$DEST/conf.d/$(basename "$f")"
  done
fi
for f in /etc/matrix-synapse/*registration*.yaml; do
  [ -f "$f" ] || continue
  do_copy "$f" "$DEST/$(basename "$f")"
done
[ "$DRY_RUN" = "0" ] && [ -d "$DEST/conf.d" ] && chmod 600 "$DEST/conf.d/"*.yaml 2>/dev/null || true
[ "$DRY_RUN" = "0" ] && chmod 600 "$DEST/"*.yaml 2>/dev/null || true

# TURN
do_copy /root/.matrix-turn-secret "$DEST/turn-secret"
[ "$DRY_RUN" = "0" ] && [ -f "$DEST/turn-secret" ] && chmod 600 "$DEST/turn-secret" 2>/dev/null || true

# TLS (Let's Encrypt: real files via -L; self-signed nginx/ssl)
for dom in "$MATRIX_DOMAIN" "$ROOT_DOMAIN"; do
  [ -d /etc/letsencrypt/live/"$dom" ] || continue
  do_copy_follow /etc/letsencrypt/live/"$dom"/fullchain.pem "$DEST/letsencrypt-$dom/fullchain.pem"
  do_copy_follow /etc/letsencrypt/live/"$dom"/privkey.pem "$DEST/letsencrypt-$dom/privkey.pem"
done
if [ -d /etc/nginx/ssl ]; then
  for f in /etc/nginx/ssl/*; do
    [ -e "$f" ] || continue
    do_copy "$f" "$DEST/nginx-ssl/$(basename "$f")"
  done
fi

# Element Call / LiveKit
do_copy /opt/element-call/.env "$DEST/element-call.env"
do_copy /opt/element-call/livekit.yaml "$DEST/element-call-livekit.yaml"
[ "$DRY_RUN" = "0" ] && [ -f "$DEST/element-call.env" ] && chmod 600 "$DEST/element-call.env" 2>/dev/null || true

# Bots
[ -f /opt/draupnir/config/production.yaml ] && do_copy /opt/draupnir/config/production.yaml "$DEST/draupnir/production.yaml"
[ "$DRY_RUN" = "0" ] && [ -f "$DEST/draupnir/production.yaml" ] && chmod 600 "$DEST/draupnir/production.yaml" 2>/dev/null || true
[ -f /opt/mjolnir/config/production.yaml ] && do_copy /opt/mjolnir/config/production.yaml "$DEST/mjolnir/production.yaml"
[ "$DRY_RUN" = "0" ] && [ -f "$DEST/mjolnir/production.yaml" ] && chmod 600 "$DEST/mjolnir/production.yaml" 2>/dev/null || true
do_copy /opt/maubot/config.yaml "$DEST/maubot-config.yaml"
[ "$DRY_RUN" = "0" ] && [ -f "$DEST/maubot-config.yaml" ] && chmod 600 "$DEST/maubot-config.yaml" 2>/dev/null || true

# Discord bridge
do_copy /opt/discord-bridge/config.yaml "$DEST/discord-bridge-config.yaml"
do_copy /etc/matrix-synapse/discord-registration.yaml "$DEST/discord-registration.yaml"
[ "$DRY_RUN" = "0" ] && [ -f "$DEST/discord-bridge-config.yaml" ] && chmod 600 "$DEST/discord-bridge-config.yaml" 2>/dev/null || true

# Coturn
do_copy /etc/turnserver.conf "$DEST/turnserver.conf"

if [ "$DRY_RUN" = "0" ]; then
  find "$DEST" -type f 2>/dev/null > "$DEST/.manifest" || true
  echo "Keys backup at $DEST"
  ls -la "$DEST"
else
  echo ""
  echo "=== End dry run ==="
fi
