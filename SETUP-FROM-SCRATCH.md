# First-time setup from scratch

**setup-from-scratch.sh** installs and configures a full Matrix stack on a fresh Debian or Ubuntu server. It prompts for your domain, server name, and options, then installs and configures everything we use: Synapse, Postgres, nginx, TLS (Let's Encrypt), coturn, optional monitoring (Netdata **or** Prometheus, not both), optional moderation bot (Draupnir or Mjolnir), fail2ban, and the backup script.

---

## Requirements

- **OS:** Debian or Ubuntu (script uses `apt`, `systemctl`, `certbot`).
- **Access:** Root or sudo. Run on the server that will host Matrix (or in a VM/container that has its own IP and hostname).
- **Network:** Ports 80 and 443 open; DNS for your Matrix hostname (and root domain if different) pointing to this host.
- **Repo:** Copy this repo to the server so the script can find config templates (synapse yamls, nginx snippets, fail2ban, netdata, backup script). Example: `scp -r hardened-matrix-stack-install-from-scratch user@server:/tmp/`

---

## Usage

```bash
# On the server, as root (or with sudo)
cd /tmp/hardened-matrix-stack-install-from-scratch   # or wherever you copied the repo
sudo ./setup-from-scratch.sh
```

The script will prompt for:

| Prompt | Example | Meaning |
|--------|---------|--------|
| **Matrix client URL** | `matrix.example.com` | Hostname clients use (Element homeserver URL). |
| **Matrix server name** | `example.com` | MXID domain (`@user:example.com`). |
| **Root domain for .well-known** | `example.com` | Where `/.well-known/matrix/client` is served (usually same as server name). |
| **Email for Let's Encrypt** | `admin@example.com` | Used for cert expiry and recovery. |
| **Enable federation?** | n | Open to other Matrix servers (yes) or client-only (no). |
| **Install coturn?** | y | TURN/STUN for voice and video. |
| **Monitoring backend** | netdata | (n)one / (net)data / (prom)etheus — exactly one. |
| **Install Element Call / LiveKit?** | n | Docker-based voice/video SFU (optional). |
| **Install fail2ban?** | y | Ban IPs after repeated login failures. |
| **Install backup script and cron?** | y | Daily backup at 03:00 to `/var/backups/matrix/`. |
| **Moderation bot** | none | (n)one / (d)raupnir / (m)jolnir. |
| **First admin user (localpart)** | admin | Creates `@admin:example.com` (password prompted). |

After the run, it prints a summary and the path to the backup script, DB config, and TURN secret.

---

## What gets installed and configured

1. **Base:** postgresql, nginx, certbot, python3, coturn (optional), fail2ban (optional).
2. **Synapse:** Matrix.org repo, `matrix-synapse-py3`; Postgres DB and user; conf.d (server_name, public_baseurl, registration off, listener with x_forwarded, url_preview off, ip_blacklist, no-federation whitelist if federation=n).
3. **nginx:** TLS via certbot; sites for Matrix (proxy to Synapse) and optional root domain (well-known + redirect); `client_max_body_size` 50M.
4. **Coturn:** TURN secret under `/root/.matrix-turn-secret`; Synapse `turn.yaml`; coturn enabled.
5. **Monitoring (optional, one of):** Netdata or Prometheus (+ node_exporter); bound to localhost when gated. Only one is installed.
6. **Fail2ban (optional):** Filter and jail for Matrix login/register (401/403/429); nginx rate-limit zones and hardening snippet (admin/metrics lockdown, rate-limited login/register).
7. **Backup (optional):** `/opt/matrix-backup/backup-matrix.sh` and cron at 03:00.

Element Call, Draupnir/Mjolnir, Maubot, and Discord bridge are optional; the script can install them when you choose the corresponding options. See README and [DRAUPNIR-INTEGRATION.md](DRAUPNIR-INTEGRATION.md).

---

## After setup

- **Create first user:** If you skipped it, run:  
  `register_new_matrix_user -c /etc/matrix-synapse/homeserver.yaml http://localhost:8008 -u YOUR_USER -p -a`
- **Element:** Point Element (web or app) to `https://<your-matrix-domain>`.
- **.well-known:** If your server name is a different domain from the Matrix hostname, ensure `https://<server-name>/.well-known/matrix/client` returns JSON with `base_url` pointing to your Matrix URL (the script configures this when root domain ≠ matrix domain).
- **Lock-down (optional):** Remove `registration_shared_secret` from `/etc/matrix-synapse/conf.d/registration.yaml` after creating all initial accounts.

---

## Idempotency and re-runs

- The script is **not** fully idempotent. It overwrites Synapse conf.d files, nginx sites, and some configs. Use it for a **fresh** server. For updates, use the individual deploy scripts (e.g. deploy-no-federation.sh, deploy-gap-and-hardening-remote.sh) or edit configs and restart services manually.
