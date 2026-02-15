# Draupnir integration

**Draupnir** is a moderation and homeserver-admin automation bot for Matrix: you run it as a bot user, give it power in rooms, and manage protected rooms, policy lists, and protections from a private management room. It also has **Synapse-specific admin features** (deactivate users, move aliases, shut down rooms, etc.) when the bot user is a Synapse admin.

We use **bot mode** (one bot instance for your server/community). Appservice mode is for multi-tenant / “Draupnir-for-all” and is not covered here.

---

## Adding Draupnir to an existing server (recommended path)

You already have Synapse, nginx, Element, TURN/STUN, etc. This path adds Draupnir without re-running the full install script.

### 1) Create the bot account and get an access token

**If you use MAS (matrix-authentication-service):** Use Draupnir’s documented MAS flow (e.g. `mas-cli manage issue-compatibility-token --yes-i-want-to-grant-synapse-admin-privileges draupnir`). Do **not** rely on the Element Web “access token” screen with MAS—those tokens can expire quickly.

**If you use normal password login (no MAS):** From your machine with this repo:

```bash
export BASE="https://matrix.example.com"   # your Matrix client URL
export SERVER_NAME="example.com"          # MXID domain
export MATRIX_PASSWORD="your-admin-password"
./setup-draupnir.sh
```

This creates `@draupnir:SERVER_NAME` (as Synapse admin), sets a password, gets an access token via login, creates the management room, invites your admin, and prints the token and room ID. Store the output; you need `DRAUPNIR_ACCESS_TOKEN` and `DRAUPNIR_MANAGEMENT_ROOM` for the server.

### 2) Management room: do **not** encrypt it

Create a **private/invite-only** room, invite the bot, and use its **room ID** as `managementRoom` in config. Draupnir **strongly recommends against encrypting the management room** and does not support E2EE for it. Use an unencrypted management room.

(The script creates the room as private_chat and invites the admin you specify; just don’t enable encryption on that room.)

### 3) Deploy on the server (Docker)

**Option A — One-shot with env (from your laptop):**

```bash
# After running setup-draupnir.sh, set the two values it printed:
export BASE="https://matrix.example.com"
export SERVER_NAME="example.com"
export DRAUPNIR_ACCESS_TOKEN="..."
export DRAUPNIR_MANAGEMENT_ROOM="!xxx:example.com"

(echo "BASE=$BASE"; echo "SERVER_NAME=$SERVER_NAME"; echo "DRAUPNIR_ACCESS_TOKEN=$DRAUPNIR_ACCESS_TOKEN"; echo "DRAUPNIR_MANAGEMENT_ROOM=$DRAUPNIR_MANAGEMENT_ROOM"; cat apply-draupnir-remote.sh) | ./run-remote-sudo.sh user@your-server
```

**Option B — Manual on the server:**

```bash
sudo mkdir -p /opt/draupnir/config /opt/draupnir/data
# Paste production.yaml (from setup-draupnir.sh output or draupnir-production.yaml with token + managementRoom set)
sudo nano /opt/draupnir/config/production.yaml

sudo docker pull gnuxie/draupnir:latest
sudo docker run -d --name draupnir --restart unless-stopped \
  -v /opt/draupnir/config/production.yaml:/data/config/production.yaml:ro \
  -v /opt/draupnir/data:/data/storage \
  gnuxie/draupnir:latest bot --draupnir-config /data/config/production.yaml
```

**Option C — systemd (alternative):** Draupnir’s docs recommend a systemd unit that pulls the image and runs the container. You can use `/var/lib/draupnir` and the unit from [Installation with Docker and systemd](https://the-draupnir-project.github.io/draupnir-documentation/bot/systemd); we use `/opt/draupnir` and `--restart unless-stopped` for consistency with the rest of this repo.

### 4) Nginx

Ensure `/_synapse/admin` is allowed from the Docker bridge so Draupnir can call the Admin API. This repo’s `nginx-synapse-hardening.conf` allows `127.0.0.1`, `::1`, and `172.17.0.0/16`. Include it in your matrix vhost and reload nginx; no extra change needed for Draupnir.

### 5) Rate limits (recommended)

Draupnir recommends disabling rate limiting for the bot account (e.g. when it redacts many messages). With Synapse you can insert a row into the `ratelimit_override` table (message rate limits only):

```bash
# On the server, as postgres (or use sudo -u postgres psql)
sudo -u postgres psql synapse -c "INSERT INTO ratelimit_override VALUES ('@draupnir:YOUR_SERVER_NAME', 0, 0) ON CONFLICT DO NOTHING;"
```

Replace `YOUR_SERVER_NAME` with your MXID domain. This only affects message rate limiting; other limits (room creation, etc.) are unchanged.

---

## First 30 minutes: make it useful

- **Protect rooms:** Invite Draupnir to a room; in the management room approve protection (or use `!draupnir rooms add …` / `!draupnir rooms list`). In each protected room, give the bot **Admin** power level when it asks.
- **Homeserver protections (if you have public registration or spam):** Draupnir can do room takedown, block invitations, and user policy protection (auto suspend from policies). Some features need the bot to be a Synapse admin (we create it as admin) or [synapse-http-antispam](https://the-draupnir-project.github.io/draupnir-documentation/bot/synapse-http-antispam) integration.

---

## E2EE reality check

- **Management room:** Keep it **unencrypted** (see above).
- **Encrypted protected rooms:** Draupnir can still protect them (ACLs, bans, server-side actions) **without** E2EE. Protections that need message content (e.g. word lists, “first message is image”) cannot work reliably in encrypted rooms because the bot can’t decrypt. You still get most of the value.

---

## Optional: synapse-http-antispam (invite/join spam)

If you see invite or join spam, you can plug [synapse-http-antispam](https://github.com/maunium/synapse-http-antispam) into Synapse and point it at Draupnir’s web API. Draupnir’s docs describe the module config and recommend **fail_open** so the homeserver doesn’t depend on Draupnir being up. See [Synapse http antispam | Draupnir Documentation](https://the-draupnir-project.github.io/draupnir-documentation/bot/synapse-http-antispam).

---

## Optional: run Draupnir on another machine

If your Synapse host is tight on memory (e.g. ~1 GB), you can run Draupnir on a separate VM or at home. It only needs **outbound** access to your homeserver; inbound is only needed if you enable web/report-forwarding or antispam callbacks.

---

## Install script (fresh install)

When you run `setup-from-scratch.sh`, you can choose **Moderation bot: (d)raupnir / (m)jolnir / (n)one**. Choosing Draupnir creates the user, room, and token and runs the container on the same server. The “add to existing server” path above is for when you **don’t** re-run the full install.

---

## Migrating from Mjolnir

1. Run `setup-draupnir.sh` to create `@draupnir` and the management room.
2. On the server, stop Mjolnir (`docker stop mjolnir`), deploy Draupnir config and start the container (see step 3 above).
3. In the Draupnir management room, re-add protected rooms and policy lists (or re-use the same rooms). Optionally remove the Mjolnir user and container later.

---

## Files in this repo

| File | Purpose |
|------|--------|
| `setup-draupnir.sh` | One-time: create @draupnir, token, management room; print config (run locally or on server). |
| `draupnir-production.yaml` | Config template (homeserverUrl, accessToken, managementRoom). |
| `apply-draupnir-remote.sh` | On server: write config from env, pull image, start container (for run-remote-sudo). |
| `backup-matrix.sh` | Backs up `/opt/draupnir` in server_config. |
