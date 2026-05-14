# Active Council Bughunt Candidate Report

This report is not a pass/fail proof. It is a fresh queue of suspicious shapes
that sit outside, or at the edge of, the current closed sweep gates. A green
all-phases council run means registered gates passed; it does not mean these
candidate lines are bugs or that no bugs exist.

Classification rule: any accepted row must be ledgered, fixed with behavior
coverage, sibling-swept, and promoted into a durable gate before closure.

## Async void boundaries

## Silent catch or lossy exception boundaries

## Callback/event invocation boundaries

## Remote/user text in diagnostics or HTTP errors

## Red-team abuse lens
scripts/run-council-active-bughunt.sh:25:    rg -n -U --with-filename --pcre2 --hidden --glob '!.git/**' --glob '!.council/**' "$pattern" "$@" || true
scripts/run-council-active-bughunt.sh:41:# Replace paths and patterns for your repo. Add narrow sections whenever a
scripts/run-council-active-bughunt.sh:61:  '(log|logger|Diagnostic|Console\.WriteLine|StatusCode\(|BadRequest\()[^;\n]*(username|query|filename|directory|token|message)' \
scripts/run-council-active-bughunt.sh:66:  '(token|secret|password|authorization|cookie|api[-_]?key|session|redirect|proxy|forwarded|path|filename|exec|spawn|shell|http://|https://)' \
scripts/check-bug-council-all-phases.sh:26:  printf 'Council all-phases runner is missing or not executable: %s\n' "${runner#$repo_root/}" >&2
docs/dev/bug-council-active-backlog.md:34:| `Red-team abuse lens` | 0 | Open | Required recurring attacker-view review across secrets, identity, redirects, paths, process launch, and downgrade risks. | Turn accepted hypotheses into behavior tests plus remediation anchors; add preservation tests for normal functionality. |
scripts/check-council-negative-space.sh:65:#   "src/path/to/sink.ext" \
docs/dev/bug-council-negative-space.md:19:| _replace_with_your_boundary_ | _network input_ | `src/path/to/sink.ext` | `ValidateInputName` |
scripts/check-remediation-baseline.sh:24:  local path="$1"
scripts/check-remediation-baseline.sh:27:  if [[ -f "$path" ]]; then
scripts/check-remediation-baseline.sh:30:    fail "$label: missing $path"
scripts/check-remediation-baseline.sh:36:  local path="$2"
scripts/check-remediation-baseline.sh:39:  if rg -n -U --pcre2 --hidden --glob '!.git/**' "$pattern" "$path" >/dev/null; then
scripts/check-remediation-baseline.sh:48:  local path="$2"
scripts/check-remediation-baseline.sh:54:  if rg -n -U --pcre2 --hidden --glob '!.git/**' "$pattern" "$path" >"$hit_file" 2>/dev/null; then
scripts/check-remediation-baseline.sh:109:# require_pattern "ValidateInputName" "src/path/to/sink" "input validator wired"
scripts/check-remediation-baseline.sh:110:# require_pattern "MaxRequestSize" "src/path/to/limit" "request size bound declared"
scripts/check-remediation-baseline.sh:113:secret_pattern='-----BEGIN (RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9_]{36,}|xox[baprs]-[A-Za-z0-9-]{20,}|AKIA[0-9A-Z]{16}|(?i)(api[_-]?key|access[_-]?token|client[_-]?secret)["'\'']?\s*[:=]\s*["'\''][A-Za-z0-9_./+=-]{24,}["'\'']'
scripts/check-remediation-baseline.sh:114:require_absent_pattern "$secret_pattern" "." "tracked text files do not contain high-confidence secret patterns"
scripts/check-council-sweep-counts.sh:82:#   "secret-pattern sweep count matches scanner"
docs/dev/bug-council-roslyn-analyzers.md:23:| CSL0004 | TaintToFilePath | High | Network-derived file/directory path without sanctioned containment validation. This catches hostile paths before filesystem sinks trust them. |
scripts/scan-bug-council-candidates.sh:24:  rg -n --with-filename --pcre2 --hidden --glob '!.git/**' "$pattern" "$@" || true
scripts/scan-bug-council-candidates.sh:33:  'PRIVATE KEY|gh[pousr]_[A-Za-z0-9_]{36,}|xox[baprs]-[A-Za-z0-9-]{20,}|AKIA[0-9A-Z]{16}|(?i)(api[_-]?key|access[_-]?token|client[_-]?secret)' \
scripts/scan-bug-council-candidates.sh:57:#   'tokio::spawn|select!|timeout\(|sleep\(|interval\(|mpsc|broadcast|oneshot' \
docs/dev/bug-council-phases.md:8:| 2 | Semantic analyzer beachhead | _Pending / In progress / Done_ | _agent_ | One language-appropriate semantic analyzer (Roslyn / Clippy / ESLint) implementing a taint-to-allocation or taint-to-path lens, with tests. |
docs/dev/bug-council-phases.md:16:| 10 | Additional semantic lens batch | _Pending / In progress / Done_ | _agent_ | Add several distinct semantic lenses in one batch, such as tainted protocol offsets, paths, timeouts, endpoints, enum/status conversions, slice bounds, diagnostic/log-line text, outbound messages, cache keys, crypto trust material, dynamic execution, parser runtimes, resource capacities, and buffer operations, with unit tests and calibration. |
docs/dev/bug-council-severity-schema.md:12:| Low | Defensive-depth gap: code path is currently unreachable from untrusted input, but the absence of the guard is itself a hazard if a refactor exposes it. |
docs/dev/bug-council-severity-schema.md:15:Pick the **worst plausible** severity given current code paths. If the same code is reachable from two boundaries with different severities, take the higher.
scripts/check-local-identity-leaks.sh:17:tmp_tokens="$(mktemp)"
scripts/check-local-identity-leaks.sh:20:trap 'rm -f "$tmp_tokens" "$tmp_commits" "$tmp_files"' EXIT
scripts/check-local-identity-leaks.sh:22:add_token() {
scripts/check-local-identity-leaks.sh:23:  local token="$1"
scripts/check-local-identity-leaks.sh:24:  token="${token//$'\n'/}"
scripts/check-local-identity-leaks.sh:25:  token="${token//$'\r'/}"
scripts/check-local-identity-leaks.sh:26:  [[ ${#token} -ge 3 ]] || return 0
scripts/check-local-identity-leaks.sh:27:  case "$token" in
scripts/check-local-identity-leaks.sh:32:  printf '%s\n' "$token" >>"$tmp_tokens"
scripts/check-local-identity-leaks.sh:35:add_token "${LOCAL_IDENTITY_DENYLIST:-}"
scripts/check-local-identity-leaks.sh:36:add_token "${SLSKDN_LOCAL_IDENTITY_DENYLIST:-}"
scripts/check-local-identity-leaks.sh:37:add_token "${SLSKDN_FORBIDDEN_LOCAL_HOSTNAME:-}"
scripts/check-local-identity-leaks.sh:38:add_token "$(hostname -s 2>/dev/null || true)"
scripts/check-local-identity-leaks.sh:39:add_token "${USER:-}"
scripts/check-local-identity-leaks.sh:40:add_token "$(id -un 2>/dev/null || true)"
scripts/check-local-identity-leaks.sh:41:add_token "$(basename "${HOME:-}" 2>/dev/null || true)"
scripts/check-local-identity-leaks.sh:43:read_csv_tokens() {
scripts/check-local-identity-leaks.sh:46:  IFS=',' read -ra tokens <<<"$value"
scripts/check-local-identity-leaks.sh:47:  for token in "${tokens[@]}"; do
scripts/check-local-identity-leaks.sh:48:    add_token "$token"
scripts/check-local-identity-leaks.sh:52:read_csv_tokens "${LOCAL_IDENTITY_DENYLIST:-}"
scripts/check-local-identity-leaks.sh:53:read_csv_tokens "${SLSKDN_LOCAL_IDENTITY_DENYLIST:-}"
scripts/check-local-identity-leaks.sh:58:  while IFS= read -r token; do
scripts/check-local-identity-leaks.sh:59:    [[ "$token" =~ ^[[:space:]]*# ]] && continue
scripts/check-local-identity-leaks.sh:60:    add_token "$token"
scripts/check-local-identity-leaks.sh:67:sort -u "$tmp_tokens" -o "$tmp_tokens"
scripts/check-local-identity-leaks.sh:68:if [[ ! -s "$tmp_tokens" ]]; then
scripts/check-local-identity-leaks.sh:69:  echo "No local identity tokens configured for scanning."
scripts/check-local-identity-leaks.sh:77:  local path="$2"
scripts/check-local-identity-leaks.sh:78:  local display_path="${3:-$path}"
scripts/check-local-identity-leaks.sh:81:  [[ -f "$path" ]] || return 0
scripts/check-local-identity-leaks.sh:83:    rg --json --fixed-strings --ignore-case --file "$tmp_tokens" "$path" |
scripts/check-local-identity-leaks.sh:84:      jq -r --arg label "$label" --arg display_path "$display_path" 'select(.type == "match") | "\($label): \($display_path):\(.data.line_number)"' |
scripts/check-local-identity-leaks.sh:96:  trap 'rm -f "$tmp_tokens" "$tmp_commits" "$tmp_files" "$tmp_unreleased"' EXIT
scripts/check-local-identity-leaks.sh:117:  -path './.git' -prune -o \
scripts/check-local-identity-leaks.sh:118:  -path './node_modules' -prune -o \
scripts/check-local-identity-leaks.sh:119:  -path './vendor' -prune -o \
scripts/check-local-identity-leaks.sh:120:  -path './target' -prune -o \
scripts/check-local-identity-leaks.sh:121:  -path './dist' -prune -o \
scripts/check-local-identity-leaks.sh:122:  -path './build' -prune -o \
scripts/check-local-identity-leaks.sh:123:  -path './zeek/pkg' -prune -o \
scripts/check-local-identity-leaks.sh:125:    -path './.github/release-notes/*' -o \
scripts/check-local-identity-leaks.sh:126:    -path './docs/dev/release-copy.md' -o \
scripts/check-local-identity-leaks.sh:127:    -path './docs/release*.md' -o \
scripts/check-local-identity-leaks.sh:128:    -path './docs/RELEASE*.md' -o \
scripts/check-local-identity-leaks.sh:129:    -path './packaging/winget/*' \
scripts/check-local-identity-leaks.sh:132:while IFS= read -r path; do
scripts/check-local-identity-leaks.sh:133:  [[ -n "$path" ]] || continue
scripts/check-local-identity-leaks.sh:134:  check_file "$path" "$path"
docs/README.md:9:| [EMERGENCY-SECRET-ROTATION-MAP.md](EMERGENCY-SECRET-ROTATION-MAP.md) | Emergency secret rotation (TLS, DB, TURN, LiveKit, etc.). |
docs/dev/bug-council-scan-registry.md:39:| Untrusted-string-to-path | Find file-system operations on caller-supplied strings without containment. |
docs/dev/bug-council-scan-registry.md:40:| Security-sensitive material | Find high-confidence private keys and token patterns. |
docs/dev/bug-council-scan-registry.md:41:| Red-team abuse lens | Re-check accepted fixes from an attacker viewpoint: spoofed identity, secret disclosure, confused deputy, replay, SSRF/path/process escape, and operational downgrade. |
docs/COMMUNITY-POLICY-LISTS.md:16:Ref: [Asgard.Chat – Subscribing to policy lists](https://asgard.chat/draupnir/subscribe-to-policy-lists.html), [Matrix.org community moderation](https://matrix.org/docs/communities/moderation).
docs/COMMUNITY-POLICY-LISTS.md:26:Repeat for other lists. To subscribe via script (e.g. after install), use `subscribe-draupnir-community-lists.sh` with admin token and management room ID.
docs/EMERGENCY-SECRET-ROTATION-MAP.md:1:# Emergency secret/key rotation map
docs/EMERGENCY-SECRET-ROTATION-MAP.md:3:This document maps **every secret and key** in the hardened Matrix stack and how to rotate them in an emergency with minimal service impact. **Do not execute these steps blindly**—treat this as a checklist and runbook. Order and restarts matter.
docs/EMERGENCY-SECRET-ROTATION-MAP.md:5:**Assumption:** You have root/sudo on the server and (where needed) access to external services (Discord Developer Portal, Let's Encrypt). User passwords and device access tokens are in the Synapse DB; rotating config/backend secrets does **not** by itself invalidate existing Matrix client sessions—except where noted (e.g. bot tokens, appservice registration).
docs/EMERGENCY-SECRET-ROTATION-MAP.md:9:## 1. Inventory: where secrets live
docs/EMERGENCY-SECRET-ROTATION-MAP.md:14:| **Registration shared secret** | `/etc/matrix-synapse/conf.d/registration.yaml` | Synapse (register_new_matrix_user) |
docs/EMERGENCY-SECRET-ROTATION-MAP.md:16:| **TURN shared secret** | `/root/.matrix-turn-secret`, `/etc/matrix-synapse/conf.d/turn.yaml`, `/etc/turnserver.conf` (static-auth-secret) | Coturn, Synapse (TURN credentials) |
docs/EMERGENCY-SECRET-ROTATION-MAP.md:21:| **Maubot** | `/opt/maubot/config.yaml` (password in URL or config) | Maubot (if used) |
docs/EMERGENCY-SECRET-ROTATION-MAP.md:22:| **Discord bridge** | `/opt/discord-bridge/config.yaml` (bot token), `/etc/matrix-synapse/discord-registration.yaml` (as_token, hs_token) | Bridge process, Synapse |
docs/EMERGENCY-SECRET-ROTATION-MAP.md:23:| **Metrics-auth proxy** | No stored secrets (uses Synapse login) | — |
docs/EMERGENCY-SECRET-ROTATION-MAP.md:24:| **Backup script** | Reads DB password from database.yaml, copies secrets to backup dir | Cron / manual |
docs/EMERGENCY-SECRET-ROTATION-MAP.md:30:**Run this step just before rotating any secret.** You can also re-run it anytime to refresh the backup (e.g. after a rotation, or on a schedule). Each run creates a timestamped snapshot so you keep a pre-rotation copy and can re-backup later without overwriting the original.
docs/EMERGENCY-SECRET-ROTATION-MAP.md:44:2. Copy all key and secret files (only if present):
docs/EMERGENCY-SECRET-ROTATION-MAP.md:53:   [ -f /root/.matrix-turn-secret ] && cp -a /root/.matrix-turn-secret "$DEST/turn-secret" && chmod 600 "$DEST/turn-secret"
docs/EMERGENCY-SECRET-ROTATION-MAP.md:78:   # Coturn (contains static-auth-secret)
docs/EMERGENCY-SECRET-ROTATION-MAP.md:92:- **`./backup-keys-pre-rotation.sh --dry-run`** — print what would be copied; no files created. Use to verify paths and LE (real files) behaviour.
docs/EMERGENCY-SECRET-ROTATION-MAP.md:98:**Before rotating anything:** Run **section 2 (Back up keys before rotate)** so you have a snapshot of all current keys and secrets. You can re-run section 2 anytime to refresh that backup.
docs/EMERGENCY-SECRET-ROTATION-MAP.md:122:- **PostgreSQL password (Synapse DB user)**
docs/EMERGENCY-SECRET-ROTATION-MAP.md:123:  - **Change:** New password in Postgres and in Synapse config.
docs/EMERGENCY-SECRET-ROTATION-MAP.md:125:    1. Generate new password (e.g. `openssl rand -hex 16`).  
docs/EMERGENCY-SECRET-ROTATION-MAP.md:127:    3. Update `/etc/matrix-synapse/conf.d/database.yaml`: set `password: NEW_PASSWORD`.  
docs/EMERGENCY-SECRET-ROTATION-MAP.md:130:  - **Impact:** All Synapse traffic stops until restart completes (~seconds). Clients reconnect; no token invalidation.
docs/EMERGENCY-SECRET-ROTATION-MAP.md:132:- **Registration shared secret**
docs/EMERGENCY-SECRET-ROTATION-MAP.md:135:    1. Generate new secret (e.g. `openssl rand -hex 32`).  
docs/EMERGENCY-SECRET-ROTATION-MAP.md:136:    2. Edit `/etc/matrix-synapse/conf.d/registration.yaml`: set `registration_shared_secret: "NEW_SECRET"`.  
docs/EMERGENCY-SECRET-ROTATION-MAP.md:137:    3. Restart Synapse (can combine with DB password restart above).  
docs/EMERGENCY-SECRET-ROTATION-MAP.md:138:  - **Impact:** Only affects `register_new_matrix_user`; existing users/sessions unchanged.
docs/EMERGENCY-SECRET-ROTATION-MAP.md:153:- **TURN shared secret**
docs/EMERGENCY-SECRET-ROTATION-MAP.md:154:  - **Change:** Same new secret in: host file, Synapse `turn.yaml`, and coturn config.
docs/EMERGENCY-SECRET-ROTATION-MAP.md:156:    1. Generate new secret: `NEW=$(openssl rand -hex 32)`.  
docs/EMERGENCY-SECRET-ROTATION-MAP.md:157:    2. `echo -n "$NEW" > /root/.matrix-turn-secret && chmod 600 /root/.matrix-turn-secret`.  
docs/EMERGENCY-SECRET-ROTATION-MAP.md:158:    3. Update **Synapse:** edit `/etc/matrix-synapse/conf.d/turn.yaml`, set `turn_shared_secret: "$NEW"` (or rewrite the file as in setup-from-scratch). `chown matrix-synapse:matrix-synapse ...`.  
docs/EMERGENCY-SECRET-ROTATION-MAP.md:159:    4. Update **coturn:** in `/etc/turnserver.conf`, replace the line `static-auth-secret=...` (the one from matrix-setup) with `static-auth-secret=$NEW`. If the block was appended by the installer, you can sed-replace that line.  
docs/EMERGENCY-SECRET-ROTATION-MAP.md:161:  - **Impact:** Existing voice/video sessions may need to reconnect; new TURN credentials will use the new secret.
docs/EMERGENCY-SECRET-ROTATION-MAP.md:167:- **LiveKit key + secret**
docs/EMERGENCY-SECRET-ROTATION-MAP.md:168:  - **Change:** New key and secret in LiveKit config and JWT service.
docs/EMERGENCY-SECRET-ROTATION-MAP.md:171:    2. Update `/opt/element-call/livekit.yaml`: replace the `keys:` block with the new key/secret.  
docs/EMERGENCY-SECRET-ROTATION-MAP.md:174:  - **Impact:** Existing Element Call / LiveKit sessions will break; clients must rejoin calls. No Synapse or nginx change.
docs/EMERGENCY-SECRET-ROTATION-MAP.md:180:- **Draupnir access token**
docs/EMERGENCY-SECRET-ROTATION-MAP.md:181:  - **Change:** New Matrix access token for the Draupnir user.
docs/EMERGENCY-SECRET-ROTATION-MAP.md:183:    1. Log in as Draupnir (or an admin) and create a new token (e.g. Element → Settings → Help & About → Access Token), or use Admin API to create a token.  
docs/EMERGENCY-SECRET-ROTATION-MAP.md:186:  - **Impact:** Old token stops working; bot uses new token. Management room and permissions unchanged if same user.
docs/EMERGENCY-SECRET-ROTATION-MAP.md:188:- **Mjolnir access token**
docs/EMERGENCY-SECRET-ROTATION-MAP.md:189:  - Same idea as Draupnir: new token in `/opt/mjolnir/config/production.yaml`, then `docker restart mjolnir`.
docs/EMERGENCY-SECRET-ROTATION-MAP.md:195:- **Maubot config / password**
docs/EMERGENCY-SECRET-ROTATION-MAP.md:196:  - **Change:** If Maubot stores a password in `/opt/maubot/config.yaml` or env, generate a new one, set it on the `@maubot` user (Admin API or change password), update config, restart Maubot (however you run it).
docs/EMERGENCY-SECRET-ROTATION-MAP.md:202:- **Discord bot token**
docs/EMERGENCY-SECRET-ROTATION-MAP.md:203:  - **Change:** New token from Discord Developer Portal (Bot → Reset Token).  
docs/EMERGENCY-SECRET-ROTATION-MAP.md:205:    1. In Discord app → Bot → Reset Token; copy new token.  
docs/EMERGENCY-SECRET-ROTATION-MAP.md:208:  - **Impact:** Old token invalidated; bridge must use new token.
docs/EMERGENCY-SECRET-ROTATION-MAP.md:210:- **Discord appservice registration (as_token, hs_token)**
docs/EMERGENCY-SECRET-ROTATION-MAP.md:211:  - **Change:** Regenerate registration so Synapse and bridge share new tokens.
docs/EMERGENCY-SECRET-ROTATION-MAP.md:213:    1. From bridge dir: `cd /opt/discord-bridge && npx -y matrix-appservice-discord -r -u "http://localhost:9005" -c config.yaml > discord-registration-new.yaml` (or similar; see bridge docs).  
docs/EMERGENCY-SECRET-ROTATION-MAP.md:218:  - **Impact:** Old appservice tokens stop working; bridge and Synapse must both use the new registration.
docs/EMERGENCY-SECRET-ROTATION-MAP.md:229:| **matrix-synapse** | After: DB password, registration secret, signing key (if done), TURN secret, Discord registration. Combine into one restart after all Synapse-related file changes. |
docs/EMERGENCY-SECRET-ROTATION-MAP.md:230:| **coturn** | After TURN secret in turnserver.conf. |
docs/EMERGENCY-SECRET-ROTATION-MAP.md:231:| **Element Call (LiveKit + auth-service)** | After LiveKit key/secret in livekit.yaml and .env. |
docs/EMERGENCY-SECRET-ROTATION-MAP.md:234:| **Discord bridge** | After config.yaml bot token and (if regenerated) after Synapse has new discord-registration.yaml. |
docs/EMERGENCY-SECRET-ROTATION-MAP.md:237:TLS → nginx reload. Then update DB password, registration secret, TURN (file + coturn config), Discord registration; restart coturn, then restart Synapse once. Then rotate LiveKit, Draupnir, Mjolnir, Discord bot token; restart those containers/processes. Metrics-auth proxy needs no restart (no stored secrets).
docs/EMERGENCY-SECRET-ROTATION-MAP.md:243:- **Backup script** (`/opt/matrix-backup/backup-matrix.sh`): Does not store its own secrets; it reads from database.yaml and copies current configs. After rotation, the next backup will contain the new secrets; ensure backup storage is secure and access-controlled.
docs/EMERGENCY-SECRET-ROTATION-MAP.md:244:- **Setup/installer scripts:** No embedded production secrets; they generate or prompt. No change needed for emergency rotation.
docs/EMERGENCY-SECRET-ROTATION-MAP.md:245:- **Cron:** No secrets; no change.
docs/EMERGENCY-SECRET-ROTATION-MAP.md:252:- Update any external documentation or password manager with new secrets.
docs/EMERGENCY-SECRET-ROTATION-MAP.md:259:- **Matrix user account passwords:** Changed by users (or admin reset); not a single “rotation” of a system secret.
docs/EMERGENCY-SECRET-ROTATION-MAP.md:260:- **Device access tokens:** Stored in Synapse DB; invalidating them is a separate operation (e.g. “logout all devices” per user).
docs/EMERGENCY-SECRET-ROTATION-MAP.md:262:- **Other appservices:** If you add more bridges/appservices, add their tokens and registration files to this map using the same pattern as Discord.
docs/EMERGENCY-SECRET-ROTATION-MAP.md:264:**Rotation script:** `./rotate-secrets.sh` runs a dry-run by default (no changes). Use `--execute` to perform rotation. Phases A–D are always automated (TLS, DB + registration, TURN, LiveKit). Phases E–G are automated when env is set: **`ADMIN_ACCESS_TOKEN`** (Synapse admin token) for Draupnir, Mjolnir, and Maubot—if unset, the script tries `secret-tool lookup service matrix-admin user "$MATRIX_DOMAIN"` (store your token with `secret-tool store service matrix-admin user matrix.example.com`). **`DISCORD_NEW_BOT_TOKEN`** (new token from Discord Developer Portal) for the bridge; Phase G skips gracefully if Discord is not set up or registration generation fails. Optional **`SERVER_NAME`** (default `ROOT_DOMAIN`) for MXIDs. Always run `backup-keys-pre-rotation.sh` first; the rotation script checks that a backup exists before `--execute`.
docs/TEST-MATRIX.md:13:| 2 | **Auth** | Registration (shared secret) | Register user via Admin API (nonce + MAC); or login if M_USER_IN_USE | k8s-qa | run-matrix-qa-tests.sh |
docs/TEST-MATRIX.md:14:| 3 | **Auth** | Login (password) | POST /login with m.login.password; receive access_token, device_id | k8s-qa | run-matrix-qa-tests.sh |
docs/TEST-MATRIX.md:15:| 4 | **Auth** | Logout | POST /logout; token invalidated | k8s-qa | run-matrix-qa-tests.sh |
docs/TEST-MATRIX.md:36:| 23 | **Admin** | Admin API (registration) | Admin API register with shared secret | k8s-qa | run-matrix-qa-tests.sh |
docs/TEST-MATRIX.md:38:| 25 | **Email** | msmtp test (alert path) | Send one test email from cluster via Gmail SMTP; credentials from Secret (never in repo). Same path fail2ban/Monit use on VM. | k8s-qa (optional) | send-test-email.sh when Secret msmtp-credentials exists |
docs/TEST-MATRIX.md:39:| 26 | **Fail2ban + email** | Ban trigger → email | On VM: fail2ban bans IP, sends email via msmtp. In k8s we only verify the email path (test 25). | VM | setup-email-alerts.sh; trigger ban then check inbox |
docs/TEST-MATRIX.md:77:   MATRIX_BASE_URL=http://<node>:30048 \
docs/TEST-MATRIX.md:79:   LIVEKIT_JWT_URL=http://<node>:30050 \
docs/TEST-MATRIX.md:97:- Use `run-matrix-qa-tests.sh` with `MATRIX_BASE_URL=https://matrix.qa.local` (and `-k` for self-signed) for 1–16.
docs/TEST-MATRIX.md:106:| **Fail2ban (sshd / matrix-synapse-auth)** | Fail2ban reads host logs (sshd, nginx); in k8s we test nginx rate-limit and email path only. |
docs/TEST-MATRIX.md:109:| **Backup cron (backup-matrix.sh)** | Host paths, DB dump; VM only. |
docs/TEST-MATRIX.md:110:| **Metrics-auth proxy** | Gates Netdata/Prometheus behind Synapse login; VM only. (Synapse /_synapse/metrics is tested in k8s.) |
docs/TEST-MATRIX.md:127:| Email alerts (msmtp, root mail) | VM + k8s optional | setup-email-alerts.sh; k8s QA verifies send path via Secret |
docs/DRAUPNIR-INTEGRATION.md:11:## Adding Draupnir to an existing server (recommended path)
docs/DRAUPNIR-INTEGRATION.md:13:You already have Synapse, nginx, Element, TURN/STUN, etc. This path adds Draupnir without re-running the full install script.
docs/DRAUPNIR-INTEGRATION.md:15:### 1) Create the bot account and get an access token
docs/DRAUPNIR-INTEGRATION.md:17:**If you use MAS (matrix-authentication-service):** Use Draupnir’s documented MAS flow (e.g. `mas-cli manage issue-compatibility-token --yes-i-want-to-grant-synapse-admin-privileges draupnir`). Do **not** rely on the Element Web “access token” screen with MAS—those tokens can expire quickly.
docs/DRAUPNIR-INTEGRATION.md:19:**If you use normal password login (no MAS):** From your machine with this repo:
docs/DRAUPNIR-INTEGRATION.md:22:export BASE="https://matrix.example.com"   # your Matrix client URL
docs/DRAUPNIR-INTEGRATION.md:24:export MATRIX_PASSWORD="your-admin-password"
docs/DRAUPNIR-INTEGRATION.md:28:This creates `@draupnir:SERVER_NAME` (as Synapse admin), sets a password, gets an access token via login, creates the management room, invites your admin, and prints the token and room ID. Store the output; you need `DRAUPNIR_ACCESS_TOKEN` and `DRAUPNIR_MANAGEMENT_ROOM` for the server.
docs/DRAUPNIR-INTEGRATION.md:42:export BASE="https://matrix.example.com"
docs/DRAUPNIR-INTEGRATION.md:54:# Paste production.yaml (from setup-draupnir.sh output or draupnir-production.yaml with token + managementRoom set)
docs/DRAUPNIR-INTEGRATION.md:64:**Option C — systemd (alternative):** Draupnir’s docs recommend a systemd unit that pulls the image and runs the container. You can use `/var/lib/draupnir` and the unit from [Installation with Docker and systemd](https://the-draupnir-project.github.io/draupnir-documentation/bot/systemd); we use `/opt/draupnir` and `--restart unless-stopped` for consistency with the rest of this repo.
docs/DRAUPNIR-INTEGRATION.md:86:- **Homeserver protections (if you have public registration or spam):** Draupnir can do room takedown, block invitations, and user policy protection (auto suspend from policies). Some features need the bot to be a Synapse admin (we create it as admin) or [synapse-http-antispam](https://the-draupnir-project.github.io/draupnir-documentation/bot/synapse-http-antispam) integration.
docs/DRAUPNIR-INTEGRATION.md:99:If you see invite or join spam, you can plug [synapse-http-antispam](https://github.com/maunium/synapse-http-antispam) into Synapse and point it at Draupnir’s web API. Draupnir’s docs describe the module config and recommend **fail_open** so the homeserver doesn’t depend on Draupnir being up. See [Synapse http antispam | Draupnir Documentation](https://the-draupnir-project.github.io/draupnir-documentation/bot/synapse-http-antispam).
docs/DRAUPNIR-INTEGRATION.md:111:When you run `setup-from-scratch.sh`, you can choose **Moderation bot: (d)raupnir / (m)jolnir / (n)one**. Choosing Draupnir creates the user, room, and token and runs the container on the same server. The “add to existing server” path above is for when you **don’t** re-run the full install.
docs/DRAUPNIR-INTEGRATION.md:127:| `setup-draupnir.sh` | One-time: create @draupnir, token, management room; print config (run locally or on server). |

## Public mutable ownership surfaces
