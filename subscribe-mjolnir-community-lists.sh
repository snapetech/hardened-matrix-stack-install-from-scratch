#!/usr/bin/env bash
# Send "!mjolnir watch #room:server" to the Mjolnir management room.
# Usage: BASE=... MANAGEMENT_ROOM_ID=... ADMIN_ACCESS_TOKEN=... ./subscribe-mjolnir-community-lists.sh
set -e
BASE="${BASE%/}"
MANAGEMENT_ROOM_ID="${MANAGEMENT_ROOM_ID:-}"
TOKEN="${ADMIN_ACCESS_TOKEN:-}"
LISTS="${COMMUNITY_LISTS:-#community-moderation-effort-bl:neko.dev}"

[ -n "$BASE" ] && [ -n "$MANAGEMENT_ROOM_ID" ] && [ -n "$TOKEN" ] || { echo "Set BASE, MANAGEMENT_ROOM_ID, ADMIN_ACCESS_TOKEN"; exit 1; }

for alias in $LISTS; do
  txn="watch-$(date +%s)-$$-$RANDOM"
  body=$(curl -sS -X PUT "$BASE/_matrix/client/r0/rooms/$(echo "$MANAGEMENT_ROOM_ID" | sed 's/!/%21/g; s/:/%3A/g')/send/m.room.message/$txn?access_token=$TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"msgtype\":\"m.text\",\"body\":\"!mjolnir watch $alias\"}" 2>/dev/null)
  echo "$body" | grep -q '"event_id"' && echo "Sent: !mjolnir watch $alias" || echo "Failed: $alias ($body)" >&2
done
echo "Subscribe commands sent. Check management room for confirmation."
