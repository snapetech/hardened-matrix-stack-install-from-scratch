# Matrix stack QA test matrix

Comprehensive test matrix for the hardened Matrix stack. All tests are designed to run **headless** in Kubernetes QA (or VM QA). Each row is a test case; **Scope** indicates where it runs (k8s-qa = minimal/full k8s; VM = run-qa-noninteractive.sh).

## Test matrix

| # | Category | Feature | Test description | Scope | Script / flow |
|---|----------|---------|------------------|--------|----------------|
| 1 | **Discovery** | Client versions | GET /_matrix/client/versions returns 200 and list of versions | k8s-qa | run-matrix-qa-tests.sh |
| 1b | **nginx** | Proxy + no-federation + .well-known | All traffic via nginx; /_matrix/federation → 403, /.well-known/matrix/server → 404, /.well-known/matrix/client → 200; rate-limit zones for login/register | k8s-qa | run-matrix-qa-tests.sh (nginx tests) |
| 1c | **nginx** | Rate limit (login) | Hammer login endpoint; nginx returns 503 when limit_req exceeded | k8s-qa | run-matrix-qa-tests.sh (test_nginx_rate_limit) |
| 1d | **Synapse** | /_synapse/metrics | GET /_synapse/metrics returns 200 and Prometheus-style output | k8s-qa | run-matrix-qa-tests.sh |
| 2 | **Auth** | Registration (shared secret) | Register user via Admin API (nonce + MAC); or login if M_USER_IN_USE | k8s-qa | run-matrix-qa-tests.sh |
| 3 | **Auth** | Login (password) | POST /login with m.login.password; receive access_token, device_id | k8s-qa | run-matrix-qa-tests.sh |
| 4 | **Auth** | Logout | POST /logout; token invalidated | k8s-qa | run-matrix-qa-tests.sh |
| 5 | **Rooms** | Create room (private) | Create private_chat room; receive room_id | k8s-qa | run-matrix-qa-tests.sh |
| 6 | **Rooms** | Create room (encrypted, E2EE) | Create room with "encryption": "m.megolm.v1.aes-sha2"; room has encryption | k8s-qa | run-matrix-qa-tests.sh |
| 7 | **Rooms** | Create room (unencrypted) | Create room without encryption; send message; no encryption state | k8s-qa | run-matrix-qa-tests.sh |
| 8 | **Rooms** | Invite user | Invite second user to room; invitee sees invite | k8s-qa | run-matrix-qa-tests.sh |
| 9 | **Rooms** | Join room | Join room by room_id; membership join | k8s-qa | run-matrix-qa-tests.sh |
| 10 | **Messaging** | Send text (plain) | Send m.room.message m.text in room; event id returned | k8s-qa | run-matrix-qa-tests.sh |
| 11 | **Messaging** | Send text in E2EE room | Send m.text in encrypted room; message stored encrypted | k8s-qa | run-matrix-qa-tests.sh |
| 12 | **Messaging** | Multiple users exchange messages | 3–5 users in same room; each sends messages; all can sync/timeline | k8s-qa | run-matrix-qa-tests.sh |
| 13 | **Media** | Upload file | POST /_matrix/media/r0/upload; receive content_uri | k8s-qa | run-matrix-qa-tests.sh |
| 14 | **Media** | Send file as message | Send m.room.message with url from upload; type m.file or m.image | k8s-qa | run-matrix-qa-tests.sh |
| 15 | **Media** | Download file | GET /_matrix/media/r0/download/...; 200 and correct body | k8s-qa | run-matrix-qa-tests.sh |
| 16 | **Media** | File in E2EE room | Upload and send file in encrypted room; download (with auth) | k8s-qa | run-matrix-qa-tests.sh |
| 17 | **Calls** | Voice/video (Element Call / LiveKit) | 1 participant: join room, get OpenID, get LiveKit JWT, connect, publish A/V | k8s-qa (full), VM | run-e2e-qa.sh (call phase) |
| 18 | **Calls** | Group video call (3 users) | 3 participants join same room; all connect to LiveKit; publish video+audio; run 30s | k8s-qa (full), VM | run-e2e-qa.sh |
| 19 | **Calls** | Group video call (5 users) | 5 participants; same as above; stress group call | k8s-qa (full), VM | run-e2e-qa.sh |
| 20 | **Calls** | Audio-only call (1:1) | 2 participants; publish audio only (no video track); 30s | k8s-qa (full), VM | run-e2e-qa.sh (--audio-only) |
| 21 | **Calls** | Audio-only group (3–5 users) | 3–5 participants; audio only; 30s | k8s-qa (full), VM | run-e2e-qa.sh (--audio-only) |
| 22 | **Sync** | Initial sync | GET /sync; receive next_batch, rooms | k8s-qa | run-matrix-qa-tests.sh |
| 22b | **Rooms** | Timeline / messages | GET /rooms/!id/messages; chunk with events | k8s-qa | run-matrix-qa-tests.sh |
| 22c | **Auth** | Whoami | GET /account/whoami; user_id returned | k8s-qa | run-matrix-qa-tests.sh |
| 23 | **Admin** | Admin API (registration) | Admin API register with shared secret | k8s-qa | run-matrix-qa-tests.sh |
| 24 | **Resilience** | 429 rate limit | (Optional) Trigger 429; retry_after_ms respected | k8s-qa | load-test / manual |
| 25 | **Email** | msmtp test (alert path) | Send one test email from cluster via Gmail SMTP; credentials from Secret (never in repo). Same path fail2ban/Monit use on VM. | k8s-qa (optional) | send-test-email.sh when Secret msmtp-credentials exists |
| 26 | **Fail2ban + email** | Ban trigger → email | On VM: fail2ban bans IP, sends email via msmtp. In k8s we only verify the email path (test 25). | VM | setup-email-alerts.sh; trigger ban then check inbox |
| 27 | **TURN (Coturn)** | Coturn + Synapse turn config | Coturn pod and Service; Synapse conf.d/turn.yaml when coturn Secret exists; Job verifies coturn:3478 reachable | k8s-qa | coturn.yaml + coturn-test-job; deploy-and-test.sh |
| 28 | **Moderation bots (Draupnir/Mjolnir)** | Bots in every room, room admin | When Secret matrix-qa-admin exists: setup Job creates @draupnir/@mjolnir, management rooms; CronJob ensures bots in all rooms and make_room_admin. Test: create room, add bots via Admin API, assert in room and PL 100. | k8s-qa (optional) | moderation-bots-setup-job, draupnir.yaml, mjolnir.yaml, ensure-moderation-bots-cronjob; run-matrix-qa-tests.sh (MODERATION_BOTS_TEST=1, MATRIX_QA_ADMIN_PASSWORD) |
| 29 | **Federation (optional)** | Federation + .well-known/server | Apply nginx-configmap-federation.yaml and restart nginx: /_matrix/federation proxied, /.well-known/matrix/server returns m.server. Isolated when no public hostname. | k8s-qa (optional) | nginx-configmap-federation.yaml; manual or CI with FEDERATION_SERVER_URL |
| 30 | **Community list subscription** | Draupnir watches CME list | Send `!draupnir watch #community-moderation-effort-bl:neko.dev` to Draupnir management room via API; assert event_id. With federation enabled, Draupnir actually subscribes. | k8s-qa (when MODERATION_BOTS_TEST=1 + MATRIX_QA_DRAUPNIR_MANAGEMENT_ROOM) | run-matrix-qa-tests.sh (test_subscribe_draupnir_community_list); deploy-and-test exports management room from Secret |

## Scope legend

- **k8s-qa**: Runs in Kubernetes QA. **Minimal** = Synapse + nginx (NodePort 30048). **Full** = + Postgres + Coturn + LiveKit + lk-jwt (NodePorts 30048, 30049, 30050).
- **VM**: Full install via `run-qa-noninteractive.sh`; then run same test scripts against that host.

## Running the full matrix

### In Kubernetes (headless)

1. **Deploy full stack** (Synapse + Postgres + LiveKit + lk-jwt):
   ```bash
   kubectl apply -f k8s-qa/
   ```
   Wait for all pods Ready (Synapse, Postgres, LiveKit, lk-jwt).

2. **Run API + file + multi-user tests** (no LiveKit required):
   ```bash
   ./k8s-qa/run-matrix-qa-tests.sh [BASE_URL]
   # Or with port-forward: ./k8s-qa/port-forward-and-test.sh
   ```

3. **Run E2E including calls** (requires LiveKit NodePorts and config):
   ```bash
   MATRIX_BASE_URL=http://<node>:30048 \
   LIVEKIT_WS_URL=ws://<node>:30049 \
   LIVEKIT_JWT_URL=http://<node>:30050 \
   SERVER_NAME=qa.local \
   ./k8s-qa/run-e2e-qa.sh
   ```
   This runs tests 1–16 then 17–21 (call tests with 3–5 synthetic participants).

### Minimal k8s (Synapse only)

If you only deploy Synapse (no LiveKit), run:
```bash
./k8s-qa/run-matrix-qa-tests.sh
```
Tests 1–16 pass; call tests (17–21) are skipped.

### VM (run-qa-noninteractive.sh)

After `sudo -E ./run-qa-noninteractive.sh` on a Debian/Ubuntu host with Element Call enabled:
- Use `load-test/` with config pointing at that host for call tests (17–21).
- Use `run-matrix-qa-tests.sh` with `MATRIX_BASE_URL=https://matrix.qa.local` (and `-k` for self-signed) for 1–16.

## Not tested in k8s-qa (VM or manual only)

These installer components are not deployed or exercised in k8s-qa; they remain VM/manual.

| Component | Reason |
|-----------|--------|
| **TLS / Certbot** | k8s-qa uses HTTP (NodePort/port-forward); TLS is VM/ingress concern. |
| **Fail2ban (sshd / matrix-synapse-auth)** | Fail2ban reads host logs (sshd, nginx); in k8s we test nginx rate-limit and email path only. |
| **Monit** | Host-level monitoring; not in k8s-qa. |
| **matrix-stack-healthcheck** | Expects systemd + Docker on host; VM only. |
| **Backup cron (backup-matrix.sh)** | Host paths, DB dump; VM only. |
| **Metrics-auth proxy** | Gates Netdata/Prometheus behind Synapse login; VM only. (Synapse /_synapse/metrics is tested in k8s.) |
| **Netdata / Prometheus** | Not deployed in k8s-qa. |
| **Draupnir / Mjolnir** | Optional in k8s-qa when Secret matrix-qa-admin exists; full Docker/cron on VM. |
| **Maubot** | Plugin bot; VM only. |
| **Discord bridge** | Appservice; VM only. |
| **OpenSSH post-quantum** | Host sshd config; VM only. |

## Newly added / optional stack features (covered elsewhere)

| Feature | Where tested | Notes |
|---------|----------------|------|
| Coturn (TURN) | k8s-qa + VM | k8s: Coturn deployed, Synapse turn.yaml, Job checks port; VM: full TURN for calls |
| Draupnir / Mjolnir | k8s-qa (optional) + VM | k8s: Job + Deployments + ensure CronJob when matrix-qa-admin Secret exists; VM: Docker + setup-draupnir/setup-mjolnir |
| Fail2ban (Synapse auth) | VM | Rate limit / ban on failed login; email on ban via msmtp |
| Monit / healthcheck | VM | matrix-stack-healthcheck; email alerts |
| Metrics (Netdata/Prometheus) | VM | Gated behind Synapse login; k8s tests raw /_synapse/metrics |
| Backup cron | VM | backup-matrix.sh |
| Email alerts (msmtp, root mail) | VM + k8s optional | setup-email-alerts.sh; k8s QA verifies send path via Secret |
