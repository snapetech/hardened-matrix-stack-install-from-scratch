#!/bin/bash
# Create @maubot:SERVER_NAME (non-admin) for maubot. Run from local when not rate limited.
# Set BASE (homeserver URL), SERVER_NAME (MXID domain), ADMIN_USER (localpart), MATRIX_PASSWORD (admin password).
# Then in maubot UI add a client: homeserver SERVER_NAME, user maubot, password below.
set -e
BASE="${BASE:-https://matrix.example.com}"
SERVER_NAME="${SERVER_NAME:-example.com}"
ADMIN_USER="${ADMIN_USER:-admin}"
PASS="${MATRIX_PASSWORD}"
if [ -z "$PASS" ]; then echo "Set MATRIX_PASSWORD (admin password for $ADMIN_USER)"; exit 1; fi
ADMIN_TOKEN=$(curl -sS -X POST "$BASE/_matrix/client/r0/login" -H "Content-Type: application/json" \
  -d "{\"type\":\"m.login.password\",\"user\":\"$ADMIN_USER\",\"password\":\"$PASS\"}" | jq -r '.access_token')
if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then echo "Failed to get admin token (rate limited?)"; exit 1; fi
MAUBOT_PW="${MAUBOT_PASSWORD:-Maub0t-$(openssl rand -hex 8)}"
curl -sS -X PUT "$BASE/_synapse/admin/v2/users/@maubot:$SERVER_NAME" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
  -d "{\"password\":\"$MAUBOT_PW\",\"admin\":false,\"logout_devices\":false}" | jq -e . >/dev/null || true
echo "Create @maubot:$SERVER_NAME done. Add client in maubot UI with:"
echo "  MAUBOT_PASSWORD=$MAUBOT_PW"
echo "  (or set MAUBOT_PASSWORD before re-running to reuse a password)"
