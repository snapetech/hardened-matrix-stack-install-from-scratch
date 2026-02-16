# Hardened Matrix stack — install from scratch

One script to install and configure a full **hardened Matrix** stack on a fresh Debian/Ubuntu server: Synapse, Postgres, nginx, TLS (Let's Encrypt), coturn, **monitoring (Netdata OR Prometheus, not both**, optionally gated behind Synapse login), fail2ban, backup cron, **Element Call (LiveKit Docker)**, **moderation bot (Draupnir OR Mjolnir, or none)**, **Maubot**, and **Discord bridge**. Everything is driven by the script; no “deploy separately” steps.

## Requirements

- **OS:** Debian or Ubuntu (script uses `apt`, `systemctl`, `certbot`).
- **Access:** Root or sudo. Run on the server that will host Matrix.
- **Network:** Ports 80 and 443 open; DNS for your Matrix hostname (and root domain if different) pointing to this host.
- **Repo:** Copy this repo to the server so the script can find config templates (e.g. `git clone` or `scp -r`).

## Quick start

```bash
# On the server, as root (or with sudo)
cd /path/to/hardened-matrix-stack-install-from-scratch
sudo ./setup-from-scratch.sh
```

**Tiny VPS (1GB/1 vCPU):** Run with `TINY_VPS=1` to default monitoring to none, use smaller DB pool (`cp_min=1`, `cp_max=5`), and apply Synapse tuning (presence off, search off, smaller cache, etc.):  
`TINY_VPS=1 ./setup-from-scratch.sh`. You can override pool size: `TINY_VPS=1 DB_CP_MIN=1 DB_CP_MAX=3 ./setup-from-scratch.sh`.

The script prompts for:

| Prompt | Example | Meaning |
|--------|---------|--------|
| **Matrix client URL** | `matrix.example.com` | Hostname clients use (Element homeserver URL). |
| **Matrix server name** | `example.com` | MXID domain (`@user:example.com`). |
| **Root domain for .well-known** | `example.com` | Where `/.well-known/matrix/client` is served. |
| **Email for Let's Encrypt** | `admin@example.com` | Cert expiry and recovery. |
| **Enable federation?** | n | Open to other Matrix servers or client-only. Default is off. **If you choose federation, a moderation bot (Draupnir or Mjolnir) is required** and the script will subscribe it to the CME community list; see [COMMUNITY-POLICY-LISTS.md](COMMUNITY-POLICY-LISTS.md). |
| **Install coturn?** | y | TURN/STUN for voice and video. |
| **Monitoring backend** | netdata | (n)one / (net)data / (prom)etheus — exactly one. |
| **Install Element Call / LiveKit?** | n | Docker-based voice/video SFU (MatrixRTC). |
| **Install fail2ban?** | y | Ban IPs after repeated login failures. |
| **Install backup script and cron?** | y | Daily backup at 03:00. |
| **Set up email alerts?** | n | msmtp (Gmail), fail2ban mail on ban, Monit, daily digest at 08:00. Needs [Gmail App Password](https://myaccount.google.com/apppasswords). |
| **Moderation bot** | none | (n)one / (d)raupnir / (m)jolnir — Draupnir is the recommended successor to Mjolnir. |
| **Install Maubot?** | n | Plugin bot. |
| **Install Discord bridge?** | n | Appservice bridge. |
| **Gate metrics behind Synapse login?** | y | metrics-auth proxy (when monitoring is installed). |
| **First admin user (localpart)** | admin | Creates `@admin:example.com` (password prompted). |

## What gets installed (all in one script)

1. **Base:** postgresql, nginx, certbot, python3, coturn (optional), fail2ban (optional).
2. **Synapse:** Matrix.org repo, Postgres DB, conf.d (server_name, registration off, listener, url_preview off, ip_blacklist, no-federation if desired).
3. **nginx + TLS:** Certbot, Matrix site (proxy to Synapse), optional root domain well-known.
4. **Coturn:** TURN secret, Synapse `turn.yaml`, coturn enabled.
5. **Monitoring (optional, one of):** **Netdata** (real-time metrics) or **Prometheus** (+ node_exporter); bound to localhost when gated. Only one backend is installed.
6. **Metrics-auth (optional, when monitoring installed):** Python proxy on 127.0.0.1:9091; nginx locations for `/metrics-auth/` (login/validate) and gated `/metrics/` (Netdata or Prometheus UI); login with Matrix account.
7. **Element Call (optional):** Docker + LiveKit server + lk-jwt-service; `/opt/element-call` with `docker-compose.yml`, `livekit.yaml`, `.env`; nginx `/livekit/jwt` and `/livekit/sfu`; Synapse experimental MSCs (3266, 4222, 4140) and `.well-known` rtc_foci.
8. **Fail2ban + nginx hardening:** Filter/jail for Synapse auth; rate-limit zones and hardening snippet.
9. **OpenSSH post-quantum KEX (idempotent):** Enables PQ-first `KexAlgorithms` to fix "store now, decrypt later" warning (OpenSSH 9.0+); skips if already set.
10. **Backup:** `/opt/matrix-backup/backup-matrix.sh` and cron at 03:00.
11. **Email alerts (optional):** msmtp + msmtp-mta (sendmail shim), fail2ban email on ban, Monit (load/memory/disk + nginx/synapse/Docker checks), daily digest at 08:00. See **setup-email-alerts.sh** (prompts for alert email and Gmail App Password).
12. **Healthcheck (optional):** **matrix-stack-healthcheck.sh** — systemd timer every 5 min (restart failed systemd units and Docker containers), Monit check with `--check-only`. Optional: `--clear-fail2ban` to unban all IPs in all jails; `--allow-reboot` for reboot-after-critical-failure. Log: `/var/log/matrix-healthcheck.log`.
13. **Moderation bot (optional, or required when federation is on):** **Draupnir** (recommended) or **Mjolnir**; creates `@draupnir` or `@mjolnir:SERVER_NAME`, management room, token; runs in Docker. When federation is enabled, the script subscribes the bot to the CME community list. See [DRAUPNIR-INTEGRATION.md](DRAUPNIR-INTEGRATION.md) and [COMMUNITY-POLICY-LISTS.md](COMMUNITY-POLICY-LISTS.md).
14. **Maubot (optional):** Creates `@maubot:SERVER_NAME`; writes `/opt/maubot/config.yaml`. You run Maubot (pip or Docker) yourself.
15. **Discord bridge (optional):** Writes `/opt/discord-bridge/config.yaml`; if `npx` is available, generates registration and adds Synapse appservice config; you start the bridge (Node or Docker).

## Non-interactive / QA

For automation or QA (e.g. in a Debian VM), use non-interactive mode and optional self-signed TLS:

```bash
# On a Debian/Ubuntu host or VM (must have systemd: PostgreSQL, nginx, Synapse start via systemctl)
sudo -E ./run-qa-noninteractive.sh
```

Defaults: `MATRIX_DOMAIN=matrix.qa.local`, `SERVER_NAME=qa.local`, `USE_SELF_SIGNED_CERT=1`. Override with env vars (see script). Set `ADMIN_PASSWORD` to create the first admin user without a prompt. Full installation requires a real Debian/Ubuntu system (or VM) with systemd; the script will fail in a minimal container without running PostgreSQL/nginx.

**Re-running the installer:** The script is re-runnable. Run it again with the same or different options: it will add previously skipped components (idempotent) and **remove or disable** optional components that you no longer select (e.g. set monitoring to none, or moderation bot to none). This applies to monitoring, metrics-auth, Element Call, fail2ban, backup cron, coturn, and Draupnir/Mjolnir.

## Testing in Kubernetes

Full E2E QA in any Kubernetes cluster (k3s, kind, minikube, etc.): deploy Synapse (optional Postgres, optional LiveKit for calls), then run the comprehensive test suite headless.

1. **Deploy and test in one go:** From repo root, `./k8s-qa/deploy-and-test.sh` (deploys all, port-forwards if needed, runs API + multi-user + file + call tests).
2. **Or deploy then test:** `kubectl apply -f k8s-qa/`, then `./k8s-qa/run-matrix-qa-tests.sh` (API only) or `./k8s-qa/run-e2e-qa.sh` with `LIVEKIT_WS_URL` and `LIVEKIT_JWT_URL` for call tests.

See **[k8s-qa/README.md](k8s-qa/README.md)** for deploy options (minimal vs full stack), access (NodePort / port-forward), and **[k8s-qa/TEST-MATRIX.md](k8s-qa/TEST-MATRIX.md)** for the full test matrix (auth, E2EE, file share, voice/video, 3–5 user group calls).

## Contents of this repo

- **setup-from-scratch.sh** — Main script (run as root).
- **run-qa-noninteractive.sh** — Wrapper for non-interactive/QA (sets `NON_INTERACTIVE=1`, `USE_SELF_SIGNED_CERT=1`, runs setup-from-scratch.sh).
- **SETUP-FROM-SCRATCH.md** — Detailed setup and prompts.
- **backup-matrix.sh** — Backup script (Synapse DB, media, conf.d, server config including Element Call, Draupnir/Mjolnir, Maubot, Discord).
- **element-call/** — `docker-compose.yml` and `livekit.yaml.template` for Element Call / LiveKit.
- **synapse-*.yaml**, **nginx-*.conf** — Config snippets and templates. **synapse-no-federation.yaml**, **nginx-no-federation.conf** — Default no-federation (spam-free); **validate-no-federation.sh**, **apply-no-federation-remote.sh** — Validate and apply on existing servers.
- **fail2ban-matrix/** — Filter and jail for Synapse auth. **fail2ban-whitelist-ssh-client.sh** (and **-remote.sh**) — whitelist your IP in sshd and unban. **matrix-stack-healthcheck.sh --clear-fail2ban** — unban all IPs in all jails.
- **setup-email-alerts.sh** — msmtp (Gmail), fail2ban mail, Monit, daily digest; run on server (prompts for email and App Password). **matrix-stack-healthcheck.sh** — healthcheck + optional restarts; timer every 5 min; `--check-only` for Monit; `--clear-fail2ban` to clear all bans; `--allow-reboot` for reboot on repeated critical failure.
- **backup-keys-pre-rotation.sh**, **rotate-secrets.sh** — Pre-rotation backup and emergency secret rotation (TLS, DB, TURN, LiveKit, Draupnir/Mjolnir, Maubot, Discord). See **EMERGENCY-SECRET-ROTATION-MAP.md**. **configure-certbot-auto-renew.sh** — set certbot timer and `renew_before_expiry = 21 days`.
- **netdata/** — Netdata bind-to-localhost config for use behind nginx.
- **metrics-auth-proxy.py**, **metrics-auth-proxy.service** — Gated metrics (Netdata or Prometheus) behind Synapse login.
- **draupnir-production.yaml**, **setup-draupnir.sh**, **apply-draupnir-remote.sh** — Draupnir (moderation bot) config template, standalone setup, and remote deploy. See [DRAUPNIR-INTEGRATION.md](DRAUPNIR-INTEGRATION.md).
- **COMMUNITY-POLICY-LISTS.md** — Recommended community block/deny lists (CME, Matrix.org COC, etc.); **subscribe-draupnir-community-lists.sh** / **subscribe-mjolnir-community-lists.sh** — send watch commands to the management room. When federation is on, the installer subscribes to CME by default.
- **mjolnir-production.yaml**, **setup-mjolnir.sh** — Mjolnir config template and standalone setup helper.
- **maubot-patch.yaml**, **setup-maubot-user.sh** — Maubot config and user-creation helper.
- **discord-bridge-config.yaml**, **synapse-appservice-discord.yaml** — Discord bridge template and Synapse appservice include.
- **k8s-qa/** — Kubernetes QA: Synapse (optional Postgres), optional LiveKit + lk-jwt for Element Call, and full headless test suite (API, multi-user, E2EE, file share, voice/video calls). See [k8s-qa/README.md](k8s-qa/README.md) and [k8s-qa/TEST-MATRIX.md](k8s-qa/TEST-MATRIX.md).

## After setup

- **First user:** If you skipped it:  
  `register_new_matrix_user -c /etc/matrix-synapse/homeserver.yaml http://localhost:8008 -u YOUR_USER -p -a`
- **Element:** Point Element to `https://<your-matrix-domain>`.
- **Metrics (if gated):** Open `https://<matrix-domain>/metrics/` and log in with your Matrix account.
- **Element Call:** If installed, clients that support MatrixRTC (e.g. Element X) will use your LiveKit backend via `.well-known` rtc_foci.
- **Lock-down (optional):** Remove `registration_shared_secret` from Synapse `conf.d/registration.yaml` after creating all initial accounts.

## Remote commands in screen

For long-running or one-off remote commands (e.g. load test, deploys), use **screen** so you can attach and monitor. Sudo still uses `run-remote-sudo.sh` (one shot, no retries).

- **Non-sudo:** `./run-remote-in-screen.sh user@texample.com <session_name> [-w] -- <command>`  
  Or pipe a script: `cat script.sh | ./run-remote-in-screen.sh user@texample.com <session_name> [-w]`  
  Attach: `ssh user@texample.com` then `screen -r <session_name>`. With `-w`, the script waits for the screen to exit then runs `screen -wipe`.
- **Sudo (once, no retries):** `./run-remote-sudo.sh user@texample.com script.sh`
- **Post-quantum SSH (fix "store now, decrypt later" warning):** `cat fix-openssh-pq-remote.sh | ./run-remote-sudo.sh user@host` — enables PQ key exchange on the server so new connections no longer warn.

## License

MIT. See [LICENSE](LICENSE).
