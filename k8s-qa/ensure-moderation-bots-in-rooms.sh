#!/usr/bin/env bash
# Ensure @draupnir and @mjolnir are in every room and are room admins.
# Uses Admin API: admin must join room first, then can add users via POST /_synapse/admin/v1/join/<room_id>.
# Then make_room_admin for both bots. Requires: ADMIN_PASSWORD only (no bot tokens).
# Run from inside cluster: BASE=http://synapse:8008, or from host with port-forward.
# Requires: curl, jq. Optional: SERVER_NAME (default qa.local).
set -e
BASE="${SYNAPSE_BASE_URL:-http://synapse:8008}"
BASE="${BASE%/}"
SERVER_NAME="${MATRIX_SERVER_NAME:-qa.local}"
ADMIN_ID="@admin:$SERVER_NAME"
DRAUPNIR_ID="@draupnir:$SERVER_NAME"
MJOLNIR_ID="@mjolnir:$SERVER_NAME"

[ -n "$ADMIN_PASSWORD" ] || { echo "ADMIN_PASSWORD not set"; exit 1; }

ADMIN_TOKEN=$(curl -sS -X POST "$BASE/_matrix/client/r0/login" -H "Content-Type: application/json" \
  -d "{\"type\":\"m.login.password\",\"user\":\"admin\",\"password\":\"$ADMIN_PASSWORD\"}" | jq -r '.access_token // empty')
[ -n "$ADMIN_TOKEN" ] || { echo "Failed to get admin token"; exit 1; }

offset=0
limit=50
while true; do
  resp=$(curl -sS -H "Authorization: Bearer $ADMIN_TOKEN" "$BASE/_synapse/admin/v1/rooms?from=$offset&limit=$limit" 2>/dev/null) || break
  rooms=$(echo "$resp" | jq -r '.rooms[]?.room_id // empty')
  [ -z "$rooms" ] && break
  for room_id in $rooms; do
    [ -z "$room_id" ] && continue
    room_enc=$(echo "$room_id" | sed 's/!/%21/g; s/:/%3A/g')
    members=$(curl -sS -H "Authorization: Bearer $ADMIN_TOKEN" "$BASE/_synapse/admin/v1/rooms/$room_enc/members" 2>/dev/null | jq -r '.members[]? // empty')
    has_admin=$(echo "$members" | grep -Fx "$ADMIN_ID" || true)
    has_d=$(echo "$members" | grep -Fx "$DRAUPNIR_ID" || true)
    has_m=$(echo "$members" | grep -Fx "$MJOLNIR_ID" || true)

    if [ -z "$has_admin" ]; then
      curl -sS -X POST -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
        -d "{\"user_id\":\"$ADMIN_ID\"}" "$BASE/_synapse/admin/v1/join/$room_enc" 2>/dev/null || true
    fi
    if [ -z "$has_d" ]; then
      curl -sS -X POST -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
        -d "{\"user_id\":\"$DRAUPNIR_ID\"}" "$BASE/_synapse/admin/v1/join/$room_enc" 2>/dev/null || true
      curl -sS -X POST -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
        -d "{\"user_id\":\"$DRAUPNIR_ID\"}" "$BASE/_synapse/admin/v1/rooms/$room_enc/make_room_admin" 2>/dev/null || true
    fi
    if [ -z "$has_m" ]; then
      curl -sS -X POST -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
        -d "{\"user_id\":\"$MJOLNIR_ID\"}" "$BASE/_synapse/admin/v1/join/$room_enc" 2>/dev/null || true
      curl -sS -X POST -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
        -d "{\"user_id\":\"$MJOLNIR_ID\"}" "$BASE/_synapse/admin/v1/rooms/$room_enc/make_room_admin" 2>/dev/null || true
    fi
  done
  next=$(echo "$resp" | jq -r '.next_batch // .next_token // empty')
  [ -z "$next" ] && break
  offset=$next
done
echo "Ensure moderation bots in rooms done."
