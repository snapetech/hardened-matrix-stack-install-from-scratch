#!/bin/bash
# Matrix backup on server. Creates a timestamped dir with:
#   - Postgres dump (synapse DB)
#   - media store tarball
#   - server signing key
#   - conf.d/ (all Synapse conf.d including database.yaml, registration.yaml — chmod 600 on secrets)
#   - optional setupdocs/ (if SETUPDOCS_PATH or /opt/matrix-backup/setupdocs exists; sync from local ~/setupdocs)
#   - server_config/ (Prometheus, Grafana, nginx, Element Call including .env, TURN secret, Mjolnir/Maubot/Discord configs, well-known, coturn, Synapse homeserver.yaml, backup script)
#   - optional k8s/ (with --k8s-friendly)
# Backup is full-secrets: protect the backup dir (0700) and any fetched copy (encrypt, restrict access). See BACKUP-CONTENTS.md.
# Run on server (e.g. cron daily). Then fetch-backups.sh to pull to local.
# Usage: sudo /opt/matrix-backup/backup-matrix.sh
#   or:   sudo /opt/matrix-backup/backup-matrix.sh /var/backups/matrix
#   or:   sudo /opt/matrix-backup/backup-matrix.sh --k8s-friendly /var/backups/matrix
# To include setup docs in each backup: rsync ~/setupdocs/ to server /opt/matrix-backup/setupdocs/
set -e
K8S_FRIENDLY=
OUTPUT_DIR=
for arg in "$@"; do
  if [ "$arg" = "--k8s-friendly" ]; then
    K8S_FRIENDLY=1
  else
    OUTPUT_DIR="$arg"
  fi
done
OUTPUT_DIR="${OUTPUT_DIR:-/var/backups/matrix}"
STAMP=$(date +%Y%m%d-%H%M%S)
DEST="${OUTPUT_DIR}/${STAMP}"
mkdir -p "$DEST"

# 1) Postgres (password from Synapse database.yaml)
DB_YAML="/etc/matrix-synapse/conf.d/database.yaml"
export PGPASSWORD
PGPASSWORD=$(sed -n 's/^[[:space:]]*password:[[:space:]]*//p' "$DB_YAML" 2>/dev/null | tr -d '\r\n')
pg_dump -U synapse -h localhost -Fc synapse -f "$DEST/synapse_db.dump"
unset PGPASSWORD

# 2) Media store
tar -czf "$DEST/media_store.tar.gz" -C /var/lib/matrix-synapse media 2>/dev/null || true

# 3) Signing key
cp -a /etc/matrix-synapse/homeserver.signing.key "$DEST/" 2>/dev/null || true

# 4) Synapse conf.d (all files so restore is one-shot; includes metrics, no-federation, url_preview, appservice refs)
mkdir -p "$DEST/conf.d"
for f in /etc/matrix-synapse/conf.d/*.yaml; do
  [ -f "$f" ] && cp -a "$f" "$DEST/conf.d/"
done
# Appservice registration files (e.g. discord-registration.yaml) often in conf.d or /etc/matrix-synapse
for f in /etc/matrix-synapse/*registration*.yaml /etc/matrix-synapse/conf.d/*registration*.yaml; do
  [ -f "$f" ] && cp -a "$f" "$DEST/conf.d/" 2>/dev/null || true
done
chmod 600 "$DEST/conf.d/database.yaml" "$DEST/conf.d/registration.yaml" 2>/dev/null || true

# 5) Optional: setup docs (sync ~/setupdocs from local to /opt/matrix-backup/setupdocs to include in backups)
SETUPDOCS="${SETUPDOCS_PATH:-/opt/matrix-backup/setupdocs}"
if [ -d "$SETUPDOCS" ]; then
  cp -a "$SETUPDOCS" "$DEST/setupdocs"
  echo "Included setup docs from $SETUPDOCS"
fi

# 6) Server config (Prometheus, Grafana, nginx, Element Call, well-known, coturn, Synapse main, secrets)
#    Includes secrets (TURN, Element Call .env, Mjolnir/Maubot/Discord configs) so one backup = full restore.
#    Backup dir is root-only (0700); protect any fetched copy (e.g. encrypt, restrict access).
SC="$DEST/server_config"
mkdir -p "$SC"
# Prometheus
[ -d /etc/prometheus ] && mkdir -p "$SC/prometheus" && cp -a /etc/prometheus/*.yml "$SC/prometheus/" 2>/dev/null || true
[ -f /etc/default/prometheus ] && cp -a /etc/default/prometheus "$SC/prometheus.default" 2>/dev/null || true
# Grafana (provisioning + conf.d; no DB)
mkdir -p "$SC/grafana"
[ -d /etc/grafana/provisioning ] && cp -a /etc/grafana/provisioning "$SC/grafana/" 2>/dev/null || true
[ -d /etc/grafana/conf.d ] && cp -a /etc/grafana/conf.d "$SC/grafana/" 2>/dev/null || true
# Nginx (sites, conf.d, snippets — matrix, root-wellknown, security, rate-limit, well-known, metrics)
mkdir -p "$SC/nginx"
[ -f /etc/nginx/sites-available/matrix ] && cp -a /etc/nginx/sites-available/matrix "$SC/nginx/" 2>/dev/null || true
[ -f /etc/nginx/sites-available/root-wellknown ] && cp -a /etc/nginx/sites-available/root-wellknown "$SC/nginx/" 2>/dev/null || true
[ -d /etc/nginx/conf.d ] && mkdir -p "$SC/nginx/conf.d" && cp -a /etc/nginx/conf.d/*.conf "$SC/nginx/conf.d/" 2>/dev/null || true
[ -d /etc/nginx/snippets ] && mkdir -p "$SC/nginx/snippets" && cp -a /etc/nginx/snippets/*.conf "$SC/nginx/snippets/" 2>/dev/null || true
# Element Call / LiveKit (Docker: compose + livekit config + .env with JWT secrets — full restorable)
[ -d /opt/element-call ] && mkdir -p "$SC/element-call" && for f in docker-compose.yml docker-compose.yaml livekit.yaml livekit.yml .env; do [ -f "/opt/element-call/$f" ] && cp -a "/opt/element-call/$f" "$SC/element-call/"; done 2>/dev/null || true
[ -f "$SC/element-call/.env" ] && chmod 600 "$SC/element-call/.env" 2>/dev/null || true
# TURN shared secret
[ -f /root/.matrix-turn-secret ] && cp -a /root/.matrix-turn-secret "$SC/turn-secret" && chmod 600 "$SC/turn-secret" 2>/dev/null || true
# Mjolnir (Docker: config with accessToken + managementRoom — full restorable)
[ -d /opt/mjolnir/config ] && mkdir -p "$SC/mjolnir" && cp -a /opt/mjolnir/config "$SC/mjolnir/" 2>/dev/null && find "$SC/mjolnir" -type f -exec chmod 600 {} \; 2>/dev/null || true
# Maubot (Docker: config.yaml with password — full restorable)
[ -f /opt/maubot/config.yaml ] && mkdir -p "$SC/maubot" && cp -a /opt/maubot/config.yaml "$SC/maubot/" && chmod 600 "$SC/maubot/config.yaml" 2>/dev/null || true
# Discord bridge (Docker: config.yaml with bot token; registration in Synapse conf.d or server_config)
[ -d /opt/discord-bridge ] && mkdir -p "$SC/discord-bridge" && cp -a /opt/discord-bridge/config.yaml "$SC/discord-bridge/" 2>/dev/null && [ -f "$SC/discord-bridge/config.yaml" ] && chmod 600 "$SC/discord-bridge/config.yaml" 2>/dev/null || true
[ -f /opt/discord-bridge/discord-registration.yaml ] && cp -a /opt/discord-bridge/discord-registration.yaml "$SC/discord-bridge/" 2>/dev/null || true
# Well-known (client discovery)
[ -d /var/www/matrix-well-known ] && cp -a /var/www/matrix-well-known "$SC/" 2>/dev/null || true
# Coturn
[ -f /etc/turnserver.conf ] && cp -a /etc/turnserver.conf "$SC/" 2>/dev/null || true
[ -f /etc/default/coturn ] && cp -a /etc/default/coturn "$SC/" 2>/dev/null || true
# Synapse main (conf.d already in DEST/conf.d; add homeserver.yaml)
[ -f /etc/matrix-synapse/homeserver.yaml ] && cp -a /etc/matrix-synapse/homeserver.yaml "$SC/" 2>/dev/null || true
# Backup script itself (so restore includes the script that made the backup)
[ -f /opt/matrix-backup/backup-matrix.sh ] && mkdir -p "$SC/matrix-backup" && cp -a /opt/matrix-backup/backup-matrix.sh "$SC/matrix-backup/" 2>/dev/null || true
# Fail2ban (matrix login jail + filter so restore can re-enable)
mkdir -p "$SC/fail2ban"
[ -f /etc/fail2ban/filter.d/matrix-synapse-auth.conf ] && cp -a /etc/fail2ban/filter.d/matrix-synapse-auth.conf "$SC/fail2ban/filter-matrix-synapse-auth.conf" 2>/dev/null || true
[ -f /etc/fail2ban/jail.d/matrix-synapse-auth.conf ] && cp -a /etc/fail2ban/jail.d/matrix-synapse-auth.conf "$SC/fail2ban/jail-matrix-synapse-auth.conf" 2>/dev/null || true
[ -n "$(ls -A "$SC" 2>/dev/null)" ] && echo "Included server_config (prometheus, grafana, nginx, element-call, well-known, coturn, synapse, backup script, fail2ban)"

# 7) Optional: k8s-friendly manifests (--k8s-friendly)
if [ -n "$K8S_FRIENDLY" ]; then
  K8S_DIR="$DEST/k8s"
  mkdir -p "$K8S_DIR"
  # Secret for signing key (kubectl apply -f k8s/secret-signing-key.yaml)
  if [ -f "$DEST/homeserver.signing.key" ]; then
    KEY_B64=$(base64 -w 0 < "$DEST/homeserver.signing.key")
    cat > "$K8S_DIR/secret-signing-key.yaml" << EOF
# Generated by backup-matrix.sh --k8s-friendly.
# Do NOT kubectl apply this file as-is in production — it contains the signing key in plaintext.
# Seal first: kubeseal -f k8s/secret-signing-key.yaml -w k8s/sealed-signing-key.yaml
apiVersion: v1
kind: Secret
metadata:
  name: synapse-signing-key
  labels:
    app.kubernetes.io/name: synapse
type: Opaque
data:
  homeserver.signing.key: $KEY_B64
EOF
    echo "Wrote $K8S_DIR/secret-signing-key.yaml"
  fi
  # ConfigMap for non-secret conf.d (optional; mount as extra config in Synapse)
  if [ -d "$DEST/conf.d" ] && [ -n "$(ls -A "$DEST/conf.d" 2>/dev/null)" ]; then
    CM_FILE="$K8S_DIR/configmap-synapse-conf.d.yaml"
    echo "apiVersion: v1" > "$CM_FILE"
    echo "kind: ConfigMap" >> "$CM_FILE"
    echo "metadata:" >> "$CM_FILE"
    echo "  name: synapse-conf.d" >> "$CM_FILE"
    echo "  labels:" >> "$CM_FILE"
    echo "    app.kubernetes.io/name: synapse" >> "$CM_FILE"
    echo "data:" >> "$CM_FILE"
    for f in "$DEST/conf.d"/*.yaml; do
      [ -f "$f" ] || continue
      name=$(basename "$f")
      echo "  $name: |" >> "$CM_FILE"
      sed 's/^/    /' "$f" >> "$CM_FILE"
    done
    echo "Wrote $CM_FILE"
  fi
  # Template for a restore Job (DB credentials from Secret; use Sealed Secrets in git. See K8S-HELM-SPEC.md.)
  cat > "$K8S_DIR/restore-job.yaml" << 'RESTOREJOB'
# Template: restore Postgres from synapse_db.dump. Customize namespace, image, volume sources.
# DB credentials: Secret synapse-db-url (e.g. PGHOST, PGUSER, PGPASSWORD, PGDATABASE or DATABASE_URL).
# Inject via Sealed Secrets at deploy time; do not commit raw Secrets. See K8S-HELM-SPEC.md.
# Ensure synapse_db.dump is available at /restore/synapse_db.dump (e.g. from a PVC).
apiVersion: batch/v1
kind: Job
metadata:
  name: synapse-db-restore
  labels:
    app.kubernetes.io/name: synapse-restore
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: restore
          image: postgres:15-alpine
          command:
            - sh
            - -c
            - |
              set -e
              export PGPASSWORD="${PGPASSWORD:-}"
              pg_restore -U "${PGUSER:-synapse}" -h "${PGHOST:-postgres}" -d synapse --no-owner --no-acl -Fc /restore/synapse_db.dump || true
          envFrom:
            - secretRef:
                name: synapse-db-url
          volumeMounts:
            - name: dump
              mountPath: /restore
              readOnly: true
      volumes:
        - name: dump
          persistentVolumeClaim:
            claimName: synapse-restore-dump   # Create PVC and upload synapse_db.dump into it
RESTOREJOB
  echo "Wrote $K8S_DIR/restore-job.yaml (template; customize PVC and Secret)"
fi

echo "Backup written to $DEST"
# Prune old backups (keep last 7 daily)
find "$OUTPUT_DIR" -maxdepth 1 -type d -name '20*' | sort -r | tail -n +8 | xargs -r rm -rf
