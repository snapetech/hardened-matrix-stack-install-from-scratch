# Emergency secret/key rotation map

This document maps **every secret and key** in the hardened Matrix stack and how to rotate them in an emergency with minimal service impact. **Do not execute these steps blindly**—treat this as a checklist and runbook. Order and restarts matter.

**Assumption:** You have root/sudo on the server and (where needed) access to external services (Discord Developer Portal, Let's Encrypt). User passwords and device access tokens are in the Synapse DB; rotating config/backend secrets does **not** by itself invalidate existing Matrix client sessions—except where noted (e.g. bot tokens, appservice registration).

---

## 1. Inventory: where secrets live

| Secret / key | Location(s) | Who uses it |
|--------------|-------------|-------------|
| **PostgreSQL (Synapse DB)** | `/etc/matrix-synapse/conf.d/database.yaml` | Synapse only |
| **Registration shared secret** | `/etc/matrix-synapse/conf.d/registration.yaml` | Synapse (register_new_matrix_user) |
| **Synapse signing key** | `/etc/matrix-synapse/homeserver.signing.key` | Synapse (federation + server identity) |
| **TURN shared secret** | `/root/.matrix-turn-secret`, `/etc/matrix-synapse/conf.d/turn.yaml`, `/etc/turnserver.conf` (static-auth-secret) | Coturn, Synapse (TURN credentials) |
| **Let's Encrypt TLS** | `/etc/letsencrypt/live/$MATRIX_DOMAIN/`, `/etc/letsencrypt/live/$ROOT_DOMAIN/` | nginx only |
| **LiveKit (Element Call)** | `/opt/element-call/.env` (LIVEKIT_KEY, LIVEKIT_SECRET), `/opt/element-call/livekit.yaml` | LiveKit server, lk-jwt-service |
| **Draupnir** | `/opt/draupnir/config/production.yaml` (accessToken) | Draupnir container |
| **Mjolnir** | `/opt/mjolnir/config/production.yaml` (accessToken) | Mjolnir container |
| **Maubot** | `/opt/maubot/config.yaml` (password in URL or config) | Maubot (if used) |
| **Discord bridge** | `/opt/discord-bridge/config.yaml` (bot token), `/etc/matrix-synapse/discord-registration.yaml` (as_token, hs_token) | Bridge process, Synapse |
| **Metrics-auth proxy** | No stored secrets (uses Synapse login) | — |
| **Backup script** | Reads DB password from database.yaml, copies secrets to backup dir | Cron / manual |

---

## 2. Back up keys before rotate (re-runnable)

**Run this step just before rotating any secret.** You can also re-run it anytime to refresh the backup (e.g. after a rotation, or on a schedule). Each run creates a timestamped snapshot so you keep a pre-rotation copy and can re-backup later without overwriting the original.

**Backup destination:** Use a root-only directory, e.g. `/var/backups/matrix-keys-pre-rotation` or `$HOME/matrix-keys-backup`. Protect the copy (encrypt in transit and at rest if you move it off the server).

**Steps (run as root or with sudo):**

1. Set a backup root and create a timestamped dir (re-run = new snapshot):
   ```bash
   KEYS_BACKUP_ROOT="${KEYS_BACKUP_ROOT:-/var/backups/matrix-keys-pre-rotation}"
   STAMP=$(date +%Y%m%d-%H%M%S)
   DEST="$KEYS_BACKUP_ROOT/$STAMP"
   umask 077 && mkdir -p "$DEST" && chmod 700 "$DEST"
   ```

2. Copy all key and secret files (only if present):
   ```bash
   # Synapse
   [ -f /etc/matrix-synapse/homeserver.signing.key ] && cp -a /etc/matrix-synapse/homeserver.signing.key "$DEST/"
   [ -d /etc/matrix-synapse/conf.d ] && mkdir -p "$DEST/conf.d" && cp -a /etc/matrix-synapse/conf.d/*.yaml "$DEST/conf.d/" 2>/dev/null || true
   for f in /etc/matrix-synapse/*registration*.yaml; do [ -f "$f" ] && cp -a "$f" "$DEST/"; done 2>/dev/null || true
   chmod 600 "$DEST/conf.d/"*.yaml "$DEST/"*.yaml 2>/dev/null || true

   # TURN
   [ -f /root/.matrix-turn-secret ] && cp -a /root/.matrix-turn-secret "$DEST/turn-secret" && chmod 600 "$DEST/turn-secret"

   # TLS (Let's Encrypt: copy real cert/key files; live/ is symlinks so use cp -L. Adjust MATRIX_DOMAIN/ROOT_DOMAIN.)
   MATRIX_DOMAIN="${MATRIX_DOMAIN:-matrix.example.com}"
   ROOT_DOMAIN="${ROOT_DOMAIN:-$MATRIX_DOMAIN}"
   for dom in "$MATRIX_DOMAIN" "$ROOT_DOMAIN"; do
     [ -d /etc/letsencrypt/live/"$dom" ] || continue
     mkdir -p "$DEST/letsencrypt-$dom"
     cp -L /etc/letsencrypt/live/"$dom"/fullchain.pem /etc/letsencrypt/live/"$dom"/privkey.pem "$DEST/letsencrypt-$dom/" 2>/dev/null || true
   done
   [ -d /etc/nginx/ssl ] && mkdir -p "$DEST/nginx-ssl" && cp -a /etc/nginx/ssl/* "$DEST/nginx-ssl/" 2>/dev/null || true

   # Element Call / LiveKit
   [ -f /opt/element-call/.env ] && cp -a /opt/element-call/.env "$DEST/element-call.env" && chmod 600 "$DEST/element-call.env"
   [ -f /opt/element-call/livekit.yaml ] && cp -a /opt/element-call/livekit.yaml "$DEST/element-call-livekit.yaml"

   # Bots
   [ -d /opt/draupnir/config ] && mkdir -p "$DEST/draupnir" && cp -a /opt/draupnir/config/production.yaml "$DEST/draupnir/" 2>/dev/null && chmod 600 "$DEST/draupnir/production.yaml"
   [ -d /opt/mjolnir/config ] && mkdir -p "$DEST/mjolnir" && cp -a /opt/mjolnir/config/production.yaml "$DEST/mjolnir/" 2>/dev/null && chmod 600 "$DEST/mjolnir/production.yaml"
   [ -f /opt/maubot/config.yaml ] && cp -a /opt/maubot/config.yaml "$DEST/maubot-config.yaml" && chmod 600 "$DEST/maubot-config.yaml"

   # Discord bridge
   [ -f /opt/discord-bridge/config.yaml ] && cp -a /opt/discord-bridge/config.yaml "$DEST/discord-bridge-config.yaml" && chmod 600 "$DEST/discord-bridge-config.yaml"
   [ -f /etc/matrix-synapse/discord-registration.yaml ] && cp -a /etc/matrix-synapse/discord-registration.yaml "$DEST/discord-registration.yaml"

   # Coturn (contains static-auth-secret)
   [ -f /etc/turnserver.conf ] && cp -a /etc/turnserver.conf "$DEST/"
   ```

3. Record what you backed up (optional):
   ```bash
   ls -la "$DEST" && find "$DEST" -type f > "$DEST/.manifest" 2>/dev/null || true
   echo "Keys backup at $DEST"
   ```

**Re-run:** Run the same steps again whenever you want a fresh snapshot (e.g. after a rotation, or on a schedule). Each run uses a new `$STAMP` so previous snapshots remain under `$KEYS_BACKUP_ROOT`. Prune old snapshots manually if needed (e.g. keep last N or last 30 days).

**Script:** A standalone script is provided so you can dry-run or run the same logic consistently:
- **`./backup-keys-pre-rotation.sh`** — create timestamped backup under `$KEYS_BACKUP_ROOT`.
- **`./backup-keys-pre-rotation.sh --dry-run`** — print what would be copied; no files created. Use to verify paths and LE (real files) behaviour.

---

## 3. Rotation order and dependencies

**Before rotating anything:** Run **section 2 (Back up keys before rotate)** so you have a snapshot of all current keys and secrets. You can re-run section 2 anytime to refresh that backup.

Rotate in this order to avoid broken links. Items that can be done in parallel are grouped.

### Phase A – TLS (minimal impact if done first)

- **Let's Encrypt certificates**
  - **Change:** Force-renew or revoke + reissue.
  - **Steps:**  
    - `certbot renew --force-renewal -d $MATRIX_DOMAIN` (and `-d $ROOT_DOMAIN` if different).  
    - Or revoke then: `certbot certonly --nginx -d $MATRIX_DOMAIN ...` (and same for root).  
  - **Then:** `nginx -t && systemctl reload nginx`.  
  - **Impact:** Brief reload; clients reconnect. No Synapse or app restarts.

- **Self-signed cert (QA):** Replace `/etc/nginx/ssl/matrix-selfsigned.{crt,key}` (generate new with openssl), then `systemctl reload nginx`.

**Certbot auto-renew:** The installer enables `certbot.timer` and sets `renew_before_expiry = 21 days` in renewal configs (renew when 21 days or less left). On existing installs, run `sudo ./configure-certbot-auto-renew.sh` (env: `MATRIX_DOMAIN`, `ROOT_DOMAIN` optional; `RENEW_BEFORE_DAYS=21` default).

**Rotation script Phase A:** The rotation script keeps forced renewals; if Certbot fails (e.g. Let's Encrypt rate limit: “too many certificates in 7 days”), Phase A is skipped and the script continues. An **ALERT** is printed to stderr so the user is notified. Current certs are unchanged; retry after the rate window.

---

### Phase B – Database and Synapse core (one restart)

- **PostgreSQL password (Synapse DB user)**
  - **Change:** New password in Postgres and in Synapse config.
  - **Steps:**  
    1. Generate new password (e.g. `openssl rand -hex 16`).  
    2. `sudo -u postgres psql -c "ALTER USER synapse WITH PASSWORD 'NEW_PASSWORD';"`  
    3. Update `/etc/matrix-synapse/conf.d/database.yaml`: set `password: NEW_PASSWORD`.  
    4. `chown matrix-synapse:matrix-synapse /etc/matrix-synapse/conf.d/database.yaml && chmod 600 ...`  
    5. `systemctl restart matrix-synapse`.  
  - **Impact:** All Synapse traffic stops until restart completes (~seconds). Clients reconnect; no token invalidation.

- **Registration shared secret**
  - **Change:** New value in `registration.yaml`.
  - **Steps:**  
    1. Generate new secret (e.g. `openssl rand -hex 32`).  
    2. Edit `/etc/matrix-synapse/conf.d/registration.yaml`: set `registration_shared_secret: "NEW_SECRET"`.  
    3. Restart Synapse (can combine with DB password restart above).  
  - **Impact:** Only affects `register_new_matrix_user`; existing users/sessions unchanged.

- **Synapse signing key**
  - **Change:** New signing key with rollover so federation and key distribution don’t break.
  - **Steps (high level):**  
    1. Generate new key (Synapse can do this; see Synapse docs for `old_signing_keys` / key rollover).  
    2. Add old key to `old_signing_keys` in config so existing signatures still verify.  
    3. Restart Synapse.  
    4. After propagation (and once nothing relies on old key), remove old key from config and restart again.  
  - **Impact:** Federation and server key distribution; do **not** rotate in a hurry unless you have a clear procedure. If you must replace without rollover, federation will break until other servers see the new key. Document your chosen method (e.g. from Synapse upgrade docs).

---

### Phase C – TURN (coturn + Synapse)

- **TURN shared secret**
  - **Change:** Same new secret in: host file, Synapse `turn.yaml`, and coturn config.
  - **Steps:**  
    1. Generate new secret: `NEW=$(openssl rand -hex 32)`.  
    2. `echo -n "$NEW" > /root/.matrix-turn-secret && chmod 600 /root/.matrix-turn-secret`.  
    3. Update **Synapse:** edit `/etc/matrix-synapse/conf.d/turn.yaml`, set `turn_shared_secret: "$NEW"` (or rewrite the file as in setup-from-scratch). `chown matrix-synapse:matrix-synapse ...`.  
    4. Update **coturn:** in `/etc/turnserver.conf`, replace the line `static-auth-secret=...` (the one from matrix-setup) with `static-auth-secret=$NEW`. If the block was appended by the installer, you can sed-replace that line.  
    5. Restart: `systemctl restart coturn`, then `systemctl restart matrix-synapse`.  
  - **Impact:** Existing voice/video sessions may need to reconnect; new TURN credentials will use the new secret.

---

### Phase D – Element Call (LiveKit)

- **LiveKit key + secret**
  - **Change:** New key and secret in LiveKit config and JWT service.
  - **Steps:**  
    1. Generate: e.g. `LIVEKIT_KEY=$(openssl rand -hex 16)`, `LIVEKIT_SECRET=$(openssl rand -base64 32)`.  
    2. Update `/opt/element-call/livekit.yaml`: replace the `keys:` block with the new key/secret.  
    3. Update `/opt/element-call/.env`: set `LIVEKIT_KEY=...`, `LIVEKIT_SECRET=...`.  
    4. Restart containers: `cd /opt/element-call && docker compose down && docker compose up -d` (or `docker-compose`).  
  - **Impact:** Existing Element Call / LiveKit sessions will break; clients must rejoin calls. No Synapse or nginx change.

---

### Phase E – Bots (Draupnir, Mjolnir)

- **Draupnir access token**
  - **Change:** New Matrix access token for the Draupnir user.
  - **Steps:**  
    1. Log in as Draupnir (or an admin) and create a new token (e.g. Element → Settings → Help & About → Access Token), or use Admin API to create a token.  
    2. Update `/opt/draupnir/config/production.yaml`: set `accessToken: NEW_TOKEN`.  
    3. `docker restart draupnir` (or stop/rm and run again with same mounts).  
  - **Impact:** Old token stops working; bot uses new token. Management room and permissions unchanged if same user.

- **Mjolnir access token**
  - Same idea as Draupnir: new token in `/opt/mjolnir/config/production.yaml`, then `docker restart mjolnir`.

---

### Phase F – Maubot

- **Maubot config / password**
  - **Change:** If Maubot stores a password in `/opt/maubot/config.yaml` or env, generate a new one, set it on the `@maubot` user (Admin API or change password), update config, restart Maubot (however you run it).

---

### Phase G – Discord bridge

- **Discord bot token**
  - **Change:** New token from Discord Developer Portal (Bot → Reset Token).  
  - **Steps:**  
    1. In Discord app → Bot → Reset Token; copy new token.  
    2. Update `/opt/discord-bridge/config.yaml`: set `auth.botToken: NEW_TOKEN`.  
    3. Restart the Discord bridge process/container.  
  - **Impact:** Old token invalidated; bridge must use new token.

- **Discord appservice registration (as_token, hs_token)**
  - **Change:** Regenerate registration so Synapse and bridge share new tokens.
  - **Steps:**  
    1. From bridge dir: `cd /opt/discord-bridge && npx -y matrix-appservice-discord -r -u "http://localhost:9005" -c config.yaml > discord-registration-new.yaml` (or similar; see bridge docs).  
    2. Replace `/etc/matrix-synapse/discord-registration.yaml` with the new file (or update in place). Ensure Synapse `app_service_config_files` points to it.  
    3. `chown matrix-synapse:matrix-synapse /etc/matrix-synapse/discord-registration.yaml`.  
    4. Restart Synapse: `systemctl restart matrix-synapse`.  
    5. Restart the Discord bridge.  
  - **Impact:** Old appservice tokens stop working; bridge and Synapse must both use the new registration.

---

## 4. Restart summary (minimal set)

To apply all rotations with as few restarts as possible:

| Restart | When |
|--------|------|
| **nginx** | After TLS (cert) rotation. |
| **matrix-synapse** | After: DB password, registration secret, signing key (if done), TURN secret, Discord registration. Combine into one restart after all Synapse-related file changes. |
| **coturn** | After TURN secret in turnserver.conf. |
| **Element Call (LiveKit + auth-service)** | After LiveKit key/secret in livekit.yaml and .env. |
| **Draupnir** | After production.yaml accessToken. |
| **Mjolnir** | After production.yaml accessToken. |
| **Discord bridge** | After config.yaml bot token and (if regenerated) after Synapse has new discord-registration.yaml. |

**Suggested order for “one sweep”:**  
TLS → nginx reload. Then update DB password, registration secret, TURN (file + coturn config), Discord registration; restart coturn, then restart Synapse once. Then rotate LiveKit, Draupnir, Mjolnir, Discord bot token; restart those containers/processes. Metrics-auth proxy needs no restart (no stored secrets).

---

## 5. Backup and scripts

- **Backup script** (`/opt/matrix-backup/backup-matrix.sh`): Does not store its own secrets; it reads from database.yaml and copies current configs. After rotation, the next backup will contain the new secrets; ensure backup storage is secure and access-controlled.
- **Setup/installer scripts:** No embedded production secrets; they generate or prompt. No change needed for emergency rotation.
- **Cron:** No secrets; no change.

---

## 6. Post-rotation

- Run a quick smoke test: HTTPS, login, one-to-one message, (if used) voice/video, (if used) bridge and bots.
- Update any external documentation or password manager with new secrets.
- If you revoked or reissued Let's Encrypt certs, ensure monitoring/alerting still works and that no legacy client is pinned to the old cert.

---

## 7. What this does *not* cover

- **Matrix user account passwords:** Changed by users (or admin reset); not a single “rotation” of a system secret.
- **Device access tokens:** Stored in Synapse DB; invalidating them is a separate operation (e.g. “logout all devices” per user).
- **SSH host keys:** Rotate separately (e.g. `ssh-keygen`, update known_hosts elsewhere).
- **Other appservices:** If you add more bridges/appservices, add their tokens and registration files to this map using the same pattern as Discord.

**Rotation script:** `./rotate-secrets.sh` runs a dry-run by default (no changes). Use `--execute` to perform rotation. Phases A–D are always automated (TLS, DB + registration, TURN, LiveKit). Phases E–G are automated when env is set: **`ADMIN_ACCESS_TOKEN`** (Synapse admin token) for Draupnir, Mjolnir, and Maubot—if unset, the script tries `secret-tool lookup service matrix-admin user "$MATRIX_DOMAIN"` (store your token with `secret-tool store service matrix-admin user matrix.example.com`). **`DISCORD_NEW_BOT_TOKEN`** (new token from Discord Developer Portal) for the bridge; Phase G skips gracefully if Discord is not set up or registration generation fails. Optional **`SERVER_NAME`** (default `ROOT_DOMAIN`) for MXIDs. Always run `backup-keys-pre-rotation.sh` first; the rotation script checks that a backup exists before `--execute`.
