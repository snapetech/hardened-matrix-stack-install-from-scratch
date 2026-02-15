#!/usr/bin/env bash
# Send "!draupnir watch #room:server" to the Draupnir management room so the bot subscribes to community policy lists.
# Requires: BASE (homeserver URL), ADMIN_ACCESS_TOKEN (or token for a user in the management room), MANAGEMENT_ROOM_ID.
# Optional: COMMUNTY_LISTS (space-separated room aliases; default: CME list only).
# Usage:
#   BASE=https://matrix.example.com MANAGEMENT_ROOM_ID='!xxx:example.com' ADMIN_ACCESS_TOKEN='...' ./subscribe-draupnir-community-lists.sh
#   COMMUNITY_LISTS='#community-moderation-effort-bl:neko.dev #matrix-org-coc-bl:matrix.org' ./subscribe-draupnir-community-lists.sh
set -e
BASE="${BASE%/}"
MANAGEMENT_ROOM_ID="${MANAGEMENT_ROOM_ID:-}"
TOKEN="${ADMIN_ACCESS_TOKEN:-$DRAUPNIR_MANAGEMENT_ROOM_TOKEN}"
LISTS="${COMMUNITY_LISTS:-#community-moderation-effort-bl:neko.dev}"

[ -n "$BASE" ] || { echo "Set BASE (homeserver URL)"; exit 1; }
[ -n "$MANAGEMENT_ROOM_ID" ] || { echo "Set MANAGEMENT_ROOM_ID (Draupnir management room ID)"; exit 1; }
[ -n "$TOKEN" ] || { echo "Set ADMIN_ACCESS_TOKEN or DRAUPNIR_MANAGEMENT_ROOM_TOKEN"; exit 1; }

for alias in $LISTS; do
  txn="watch-$(date +%s)-$$-$RANDOM"
  body=$(curl -sS -X PUT "$BASE/_matrix/client/r0/rooms/$(echo "$MANAGEMENT_ROOM_ID" | sed 's/!/%21/g; s/:/%3A/g')/send/m.room.message/$txn?access_token=$TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"msgtype\":\"m.text\",\"body\":\"!draupnir watch $alias\"}" 2>/dev/null)
  if echo "$body" | grep -q '"event_id"'; then
    echo "Sent: !draupnir watch $alias"
  else
    echo "Failed or rate-limited: $alias ($body)" >&2
  fi
done
echo "Subscribe commands sent. Draupnir will process them; check the management room for confirmation."
