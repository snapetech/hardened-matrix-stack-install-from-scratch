#!/bin/bash
# One-time setup: create @draupnir:SERVER_NAME (admin), get token, create management room.
# Run from local or server. Needs: curl, jq.
# Set BASE (homeserver URL), SERVER_NAME (MXID domain), ADMIN_USER (localpart), MATRIX_PASSWORD (admin password).
# Outputs: production.yaml contents and DRAUPNIR_ACCESS_TOKEN / management_room_id for Docker.
set -e
BASE="${BASE:-https://matrix.example.com}"
SERVER_NAME="${SERVER_NAME:-example.com}"
ADMIN_USER="${ADMIN_USER:-admin}"
PASS="${MATRIX_PASSWORD}"
if [ -z "$PASS" ]; then echo "Set MATRIX_PASSWORD (admin password for $ADMIN_USER)"; exit 1; fi

# 1) Admin token
ADMIN_TOKEN=$(curl -sS -X POST "$BASE/_matrix/client/r0/login" \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"m.login.password\",\"user\":\"$ADMIN_USER\",\"password\":\"$PASS\"}" | jq -r '.access_token')
if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then echo "Failed to get admin token"; exit 1; fi

# 2) Create or update draupnir user (admin). Use DRAUPNIR_PASSWORD if user already exists.
DRAUPNIR_PASSWORD="${DRAUPNIR_PASSWORD:-$(openssl rand -base64 24)}"
curl -sS -X PUT "$BASE/_synapse/admin/v2/users/@draupnir:$SERVER_NAME" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"password\":\"$DRAUPNIR_PASSWORD\",\"admin\":true,\"logout_devices\":false}" | jq -e . >/dev/null || true

# 3) Get draupnir access token (if rate limited, wait retry_after_ms and re-run)
DRAUPNIR_TOKEN=$(curl -sS -X POST "$BASE/_matrix/client/r0/login" \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"m.login.password\",\"user\":\"draupnir\",\"password\":\"$DRAUPNIR_PASSWORD\"}" | jq -r '.access_token // empty')
if [ -z "$DRAUPNIR_TOKEN" ]; then
  echo "Failed to get draupnir token (M_LIMIT_EXCEEDED? wait retry_after_ms and re-run with DRAUPNIR_PASSWORD=$DRAUPNIR_PASSWORD)" >&2
  exit 1
fi

# 4) Create management room (as draupnir)
ROOM_ID=$(curl -sS -X POST "$BASE/_matrix/client/r0/createRoom" \
  -H "Authorization: Bearer $DRAUPNIR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"Draupnir management","preset":"private_chat"}' | jq -r '.room_id')
if [ -z "$ROOM_ID" ] || [ "$ROOM_ID" = "null" ]; then echo "Failed to create room"; exit 1; fi

# 5) Invite admin so they can see the room and run !draupnir commands
INVITE_USER="${INVITE_USER:-$ADMIN_USER}"
INVITE_USER_ID="@${INVITE_USER}:$SERVER_NAME"
invite_resp=$(curl -sS -X POST "$BASE/_matrix/client/r0/rooms/${ROOM_ID}/invite" \
  -H "Authorization: Bearer $DRAUPNIR_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"user_id\":\"$INVITE_USER_ID\"}")
if echo "$invite_resp" | jq -e .room_id >/dev/null 2>&1; then
  echo "Invited $INVITE_USER_ID to management room (they should see it in Element)."
elif echo "$invite_resp" | jq -e .errcode >/dev/null 2>&1; then
  echo "Warning: invite returned $(echo "$invite_resp" | jq -r '.errcode // "error"') — $INVITE_USER_ID may already be in the room or invite failed. Check Element."
else
  echo "Invited $INVITE_USER_ID to management room."
fi

echo "Draupnir user: @draupnir:$SERVER_NAME (admin)"
echo "Management room_id: $ROOM_ID"
echo "Store these for the server; do not commit tokens."
echo "DRAUPNIR_ACCESS_TOKEN=$DRAUPNIR_TOKEN"
echo "DRAUPNIR_MANAGEMENT_ROOM=$ROOM_ID"
echo "---"
echo "On server: create /opt/draupnir/config/production.yaml with:"
echo "  homeserverUrl: $BASE"
echo "  rawHomeserverUrl: $BASE"
echo "  accessToken: <token above>"
echo "  managementRoom: \"$ROOM_ID\""
echo "  dataPath: /data/storage"
echo ""
echo "Nginx: ensure /_synapse/admin is allowed from Docker (e.g. include nginx-synapse-hardening.conf"
echo "  which allows 127.0.0.1, ::1, 172.17.0.0/16). Otherwise Draupnir gets 403 when checking admin status."
echo ""
echo "Management room: keep it UNENCRYPTED (Draupnir strongly recommends this)."
echo "Rate limits (optional but recommended): on the server run:"
echo "  sudo -u postgres psql synapse -c \"INSERT INTO ratelimit_override VALUES ('@draupnir:$SERVER_NAME', 0, 0) ON CONFLICT DO NOTHING;\""
