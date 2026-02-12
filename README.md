# Hardened Matrix stack — install from scratch

One script to install and configure a full **hardened Matrix** stack on a fresh Debian/Ubuntu server: Synapse, Postgres, nginx, TLS (Let's Encrypt), coturn, Prometheus + Grafana (optionally gated behind Synapse login), fail2ban, backup cron, **Element Call (LiveKit Docker)**, **Mjolnir**, **Maubot**, and **Discord bridge**. Everything is driven by the script; no “deploy separately” steps.

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

The script prompts for:

| Prompt | Example | Meaning |
|--------|---------|--------|
| **Matrix client URL** | `matrix.example.com` | Hostname clients use (Element homeserver URL). |
| **Matrix server name** | `example.com` | MXID domain (`@user:example.com`). |
| **Root domain for .well-known** | `example.com` | Where `/.well-known/matrix/client` is served. |
| **Email for Let's Encrypt** | `admin@example.com` | Cert expiry and recovery. |
| **Enable federation?** | n | Open to other Matrix servers or client-only. |
| **Install coturn?** | y | TURN/STUN for voice and video. |
| **Install Prometheus + Grafana?** | y | Metrics and dashboards. |
| **Install Element Call / LiveKit?** | n | Docker-based voice/video SFU (MatrixRTC). |
| **Install fail2ban?** | y | Ban IPs after repeated login failures. |
| **Install backup script and cron?** | y | Daily backup at 03:00. |
| **Install Mjolnir?** | n | Moderation bot (Docker). |
| **Install Maubot?** | n | Plugin bot. |
| **Install Discord bridge?** | n | Appservice bridge. |
| **Gate Prometheus/Grafana behind Synapse login?** | y | metrics-auth proxy (when monitoring is installed). |
| **First admin user (localpart)** | admin | Creates `@admin:example.com` (password prompted). |

## What gets installed (all in one script)

1. **Base:** postgresql, nginx, certbot, python3, coturn (optional), fail2ban (optional).
2. **Synapse:** Matrix.org repo, Postgres DB, conf.d (server_name, registration off, listener, url_preview off, ip_blacklist, no-federation if desired).
3. **nginx + TLS:** Certbot, Matrix site (proxy to Synapse), optional root domain well-known.
4. **Coturn:** TURN secret, Synapse `turn.yaml`, coturn enabled.
5. **Monitoring (optional):** Prometheus + node exporter, Grafana; scrape config, alerts, recording rules; Grafana provisioning (dashboard + datasource).
6. **Metrics-auth (optional, when monitoring=y):** Python proxy on 127.0.0.1:9091; nginx locations for `/metrics-auth/` (login/validate) and gated `/metrics/` and `/metrics/grafana/`; Prometheus bound to localhost with external-url; Grafana subpath.
7. **Element Call (optional):** Docker + LiveKit server + lk-jwt-service; `/opt/element-call` with `docker-compose.yml`, `livekit.yaml`, `.env`; nginx `/livekit/jwt` and `/livekit/sfu`; Synapse experimental MSCs (3266, 4222, 4140) and `.well-known` rtc_foci.
8. **Fail2ban + nginx hardening:** Filter/jail for Synapse auth; rate-limit zones and hardening snippet.
9. **Backup:** `/opt/matrix-backup/backup-matrix.sh` and cron at 03:00.
10. **Mjolnir (optional):** Creates `@mjolnir:SERVER_NAME`, management room, token; writes `/opt/mjolnir/config/production.yaml`; runs Mjolnir in Docker.
11. **Maubot (optional):** Creates `@maubot:SERVER_NAME`; writes `/opt/maubot/config.yaml`. You run Maubot (pip or Docker) yourself.
12. **Discord bridge (optional):** Writes `/opt/discord-bridge/config.yaml`; if `npx` is available, generates registration and adds Synapse appservice config; you start the bridge (Node or Docker).

## Non-interactive / QA

For automation or QA (e.g. in a Debian VM), use non-interactive mode and optional self-signed TLS:

```bash
# On a Debian/Ubuntu host or VM (must have systemd: PostgreSQL, nginx, Synapse start via systemctl)
sudo -E ./run-qa-noninteractive.sh
```

Defaults: `MATRIX_DOMAIN=matrix.qa.local`, `SERVER_NAME=qa.local`, `USE_SELF_SIGNED_CERT=1`. Override with env vars (see script). Set `ADMIN_PASSWORD` to create the first admin user without a prompt. Full installation requires a real Debian/Ubuntu system (or VM) with systemd; the script will fail in a minimal container without running PostgreSQL/nginx.

## Testing in Kubernetes

To run the Matrix client API test suite against a minimal Synapse instance in any Kubernetes cluster (k3s, kind, minikube, etc.):

1. **Deploy:** `kubectl apply -f k8s-qa/` (wait for pod `1/1` Ready).
2. **Run tests:** From repo root, `./k8s-qa/run-matrix-qa-tests.sh` (NodePort 30048), or `./k8s-qa/port-forward-and-test.sh` when not on the node.

See **[k8s-qa/README.md](k8s-qa/README.md)** for deploy, access (NodePort / port-forward), test script options, and teardown.

## Contents of this repo

- **setup-from-scratch.sh** — Main script (run as root).
- **run-qa-noninteractive.sh** — Wrapper for non-interactive/QA (sets `NON_INTERACTIVE=1`, `USE_SELF_SIGNED_CERT=1`, runs setup-from-scratch.sh).
- **SETUP-FROM-SCRATCH.md** — Detailed setup and prompts.
- **backup-matrix.sh** — Backup script (Synapse DB, media, conf.d, server config including Element Call, Mjolnir, Maubot, Discord).
- **element-call/** — `docker-compose.yml` and `livekit.yaml.template` for Element Call / LiveKit.
- **synapse-*.yaml**, **nginx-*.conf** — Config snippets and templates.
- **fail2ban-matrix/** — Filter and jail for Synapse auth.
- **grafana/** — Provisioning (datasources, dashboards) and conf.d.
- **prometheus-*.yml** — Prometheus config, alerts, recording rules.
- **metrics-auth-proxy.py**, **metrics-auth-proxy.service** — Gated metrics behind Synapse login.
- **mjolnir-production.yaml**, **setup-mjolnir.sh** — Mjolnir config template and standalone setup helper.
- **maubot-patch.yaml**, **setup-maubot-user.sh** — Maubot config and user-creation helper.
- **discord-bridge-config.yaml**, **synapse-appservice-discord.yaml** — Discord bridge template and Synapse appservice include.
- **k8s-qa/** — Kubernetes manifests and scripts to run a minimal Synapse QA instance and the Matrix API test suite; see [k8s-qa/README.md](k8s-qa/README.md).

## After setup

- **First user:** If you skipped it:  
  `register_new_matrix_user -c /etc/matrix-synapse/homeserver.yaml http://localhost:8008 -u YOUR_USER -p -a`
- **Element:** Point Element to `https://<your-matrix-domain>`.
- **Metrics (if gated):** Open `https://<matrix-domain>/metrics/` and log in with your Matrix account.
- **Element Call:** If installed, clients that support MatrixRTC (e.g. Element X) will use your LiveKit backend via `.well-known` rtc_foci.
- **Lock-down (optional):** Remove `registration_shared_secret` from Synapse `conf.d/registration.yaml` after creating all initial accounts.

## License

MIT. See [LICENSE](LICENSE).
