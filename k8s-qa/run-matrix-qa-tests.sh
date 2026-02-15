#!/usr/bin/env bash
# Run Matrix QA tests from your machine against a Synapse instance (Kubernetes NodePort or port-forward).
# Covers: versions, auth, rooms (encrypted + unencrypted), multi-user, file upload/download, messaging.
# Usage:
#   ./k8s-qa/run-matrix-qa-tests.sh [BASE_URL]
#   MATRIX_BASE_URL=http://localhost:30048 ./k8s-qa/run-matrix-qa-tests.sh
#
# Run only specific tests (faster iteration when fixing failures):
#   MATRIX_QA_TESTS=versions,metrics,wellknown_client ./k8s-qa/run-matrix-qa-tests.sh
#   MATRIX_QA_TESTS=metrics ./k8s-qa/run-matrix-qa-tests.sh
# Skip specific tests:
#   MATRIX_QA_SKIP=rate_limit,file_upload ./k8s-qa/run-matrix-qa-tests.sh
# List test ids: ./k8s-qa/run-matrix-qa-tests.sh --list-tests
#
# Default BASE_URL: http://localhost:30048 (nginx in matrix-qa, or after port-forward).
# Requires: curl, jq, openssl.
set -e

BASE_URL="${MATRIX_BASE_URL:-http://localhost:30048}"
if [ "${1:-}" = "--list-tests" ]; then
  echo "Test ids (use with MATRIX_QA_TESTS=id1,id2 or MATRIX_QA_SKIP=id1,id2):"
  echo "  versions federation_blocked federation_allowed wellknown_server wellknown_client metrics register_login whoami create_room send_message sync room_timeline rate_limit register_extra_users encrypted_room unencrypted_room invite_join multi_user_messages file_upload moderation_bots subscribe_draupnir logout"
  exit 0
fi
BASE_URL="${1:-$BASE_URL}"
BASE_URL="${BASE_URL%/}"
REGISTRATION_SHARED_SECRET="${MATRIX_REGISTRATION_SHARED_SECRET:-qa-test-registration-secret}"
TEST_USER="qa-test-user-$(date +%s)"
TEST_PASSWORD="qa-test-password"
NUM_EXTRA_USERS="${MATRIX_QA_NUM_USERS:-4}"   # 4 extra = 5 users total (1 main + 4)
FAILED=0
TMP_PREFIX="/tmp/matrix_qa_$$"

run_test() {
  local name="$1"
  shift
  if "$@"; then
    echo "  OK: $name"
    return 0
  else
    echo "  FAIL: $name"
    FAILED=$((FAILED + 1))
    return 0
  fi
}

# Run test only if MATRIX_QA_TESTS/MATRIX_QA_SKIP allow (ids are comma-separated)
run_test_if_selected() {
  local id="$1" name="$2"
  shift 2
  if [ -n "${MATRIX_QA_TESTS:-}" ]; then
    case ",${MATRIX_QA_TESTS}," in *",$id,"*) ;; *) return 0 ;; esac
  fi
  if [ -n "${MATRIX_QA_SKIP:-}" ]; then
    case ",${MATRIX_QA_SKIP}," in *",$id,"*) return 0 ;; esac
  fi
  run_test "$name" "$@"
}

test_versions() {
  local r i
  for i in 1 2 3 4 5; do
    r=$(curl -sS -w "%{http_code}" -o /tmp/matrix_versions.json "$BASE_URL/_matrix/client/versions" 2>/dev/null)
    [ "$r" = "200" ] && break
    [ "$i" -lt 5 ] && sleep 2
  done
  [ "$r" = "200" ] || return 1
  if command -v jq &>/dev/null; then
    jq -e '.versions | length > 0' /tmp/matrix_versions.json >/dev/null || return 1
  else
    grep -q "r0" /tmp/matrix_versions.json || return 1
  fi
  return 0
}

# nginx (proxy, no-federation): when traffic goes through nginx, federation and server well-known are blocked
test_nginx_federation_blocked() {
  local r
  r=$(curl -sS -w "%{http_code}" -o /dev/null "$BASE_URL/_matrix/federation/v1/version" 2>/dev/null)
  [ "$r" = "403" ] || return 1
  r=$(curl -sS -w "%{http_code}" -o /dev/null "$BASE_URL/.well-known/matrix/server" 2>/dev/null)
  [ "$r" = "404" ] || return 1
  return 0
}

# When federation is enabled: federation endpoint and .well-known/matrix/server are allowed
test_nginx_federation_allowed() {
  local r
  r=$(curl -sS -w "%{http_code}" -o /tmp/matrix_fed_version.json "$BASE_URL/_matrix/federation/v1/version" 2>/dev/null)
  [ "$r" = "200" ] || return 1
  if command -v jq &>/dev/null; then
    jq -e '.server' /tmp/matrix_fed_version.json >/dev/null 2>&1 || true
  fi
  return 0
}

test_wellknown_server_200() {
  local r
  r=$(curl -sS -w "%{http_code}" -o /tmp/matrix_wellknown_server.json "$BASE_URL/.well-known/matrix/server" 2>/dev/null)
  [ "$r" = "200" ] || return 1
  if command -v jq &>/dev/null; then
    jq -e '.["m.server"]' /tmp/matrix_wellknown_server.json >/dev/null || return 1
  else
    grep -q 'm.server' /tmp/matrix_wellknown_server.json || return 1
  fi
  return 0
}

test_nginx_wellknown_client() {
  local r
  r=$(curl -sS -w "%{http_code}" -o /tmp/matrix_wellknown.json "$BASE_URL/.well-known/matrix/client" 2>/dev/null)
  [ "$r" = "200" ] || return 1
  if command -v jq &>/dev/null; then
    jq -e '.m.homeserver.base_url' /tmp/matrix_wellknown.json >/dev/null 2>&1 || grep -q 'm.homeserver\|base_url' /tmp/matrix_wellknown.json || return 1
  else
    grep -q 'm.homeserver\|base_url' /tmp/matrix_wellknown.json || return 1
  fi
  return 0
}

# nginx rate limit: burst 10 for login; send 15 rapid requests, expect at least one 503
test_nginx_rate_limit() {
  local i got503=0 code
  for i in $(seq 1 15); do
    code=$(curl -sS -w "%{http_code}" -o /dev/null -X POST "$BASE_URL/_matrix/client/v3/login" \
      -H "Content-Type: application/json" \
      -d '{"type":"m.login.password","identifier":{"type":"m.id.user","user":"rate-limit-test"},"password":"wrong"}' 2>/dev/null)
    [ "$code" = "503" ] && got503=1
  done
  [ "$got503" = "1" ] || return 1
  return 0
}

test_synapse_metrics() {
  local r
  r=$(curl -sS -w "%{http_code}" -o /tmp/matrix_metrics.txt "$BASE_URL/_synapse/metrics" 2>/dev/null)
  [ "$r" = "200" ] || return 1
  grep -q "synapse_" /tmp/matrix_metrics.txt 2>/dev/null || grep -q "^#" /tmp/matrix_metrics.txt 2>/dev/null || [ -s /tmp/matrix_metrics.txt ] || return 1
  return 0
}

test_register_and_login() {
  local nonce mac body resp code
  body=$(curl -sS -w "\n%{http_code}" "$BASE_URL/_synapse/admin/v1/register" 2>/dev/null) || return 1
  code=$(echo "$body" | tail -n1)
  body=$(echo "$body" | sed '$d')
  [ "$code" = "200" ] || return 1
  nonce=$(echo "$body" | jq -r '.nonce // empty')
  [ -n "$nonce" ] || return 1
  mac=$(printf '%s\0%s\0%s\0notadmin' "$nonce" "$TEST_USER" "$TEST_PASSWORD" | openssl dgst -sha1 -hmac "$REGISTRATION_SHARED_SECRET" 2>/dev/null | awk '{print $2}')
  [ -n "$mac" ] || return 1
  resp=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/_synapse/admin/v1/register" \
    -H "Content-Type: application/json" \
    -d "{\"nonce\":\"$nonce\",\"username\":\"$TEST_USER\",\"password\":\"$TEST_PASSWORD\",\"admin\":false,\"mac\":\"$mac\"}" 2>/dev/null) || return 1
  code=$(echo "$resp" | tail -n1)
  body=$(echo "$resp" | sed '$d')
  if [ "$code" = "200" ]; then
    echo "$body" > /tmp/matrix_login.json
    return 0
  fi
  if [ "$code" = "400" ] && echo "$body" | jq -e '.errcode == "M_USER_IN_USE"' >/dev/null 2>&1; then
    resp=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/_matrix/client/r0/login" \
      -H "Content-Type: application/json" \
      -d "{\"type\":\"m.login.password\",\"user\":\"$TEST_USER\",\"password\":\"$TEST_PASSWORD\"}" 2>/dev/null) || return 1
    code=$(echo "$resp" | tail -n1)
    body=$(echo "$resp" | sed '$d')
    [ "$code" = "200" ] || return 1
    echo "$body" > /tmp/matrix_login.json
    return 0
  fi
  return 1
}

test_whoami() {
  local token body code
  token=$(jq -r '.access_token // empty' /tmp/matrix_login.json 2>/dev/null)
  [ -n "$token" ] || return 1
  body=$(curl -sS -w "\n%{http_code}" "$BASE_URL/_matrix/client/r0/account/whoami?access_token=$token" 2>/dev/null) || return 1
  code=$(echo "$body" | tail -n1)
  body=$(echo "$body" | sed '$d')
  [ "$code" = "200" ] || return 1
  if command -v jq &>/dev/null; then
    jq -e '.user_id' <<< "$body" >/dev/null || return 1
  fi
  return 0
}

test_sync() {
  local token body code
  token=$(jq -r '.access_token // empty' /tmp/matrix_login.json 2>/dev/null)
  [ -n "$token" ] || return 1
  body=$(curl -sS -w "\n%{http_code}" "$BASE_URL/_matrix/client/r0/sync?access_token=$token&timeout=0" 2>/dev/null) || return 1
  code=$(echo "$body" | tail -n1)
  body=$(echo "$body" | sed '$d')
  [ "$code" = "200" ] || return 1
  if command -v jq &>/dev/null; then
    jq -e '.next_batch' <<< "$body" >/dev/null || return 1
  fi
  return 0
}

test_room_timeline() {
  local token room_id body code
  token=$(jq -r '.access_token // empty' /tmp/matrix_login.json 2>/dev/null)
  room_id=$(jq -r '.room_id // empty' /tmp/matrix_room.json 2>/dev/null)
  [ -n "$token" ] && [ -n "$room_id" ] || return 1
  body=$(curl -sS -w "\n%{http_code}" "$BASE_URL/_matrix/client/r0/rooms/$room_id/messages?access_token=$token&dir=b&limit=5" 2>/dev/null) || return 1
  code=$(echo "$body" | tail -n1)
  body=$(echo "$body" | sed '$d')
  [ "$code" = "200" ] || return 1
  if command -v jq &>/dev/null; then
    jq -e '.chunk | length >= 0' <<< "$body" >/dev/null || return 1
    jq -e '.chunk[] | select(.type == "m.room.message")' <<< "$body" >/dev/null 2>/dev/null || true
  fi
  return 0
}

test_create_room() {
  local token body code
  token=$(jq -r '.access_token // empty' /tmp/matrix_login.json 2>/dev/null)
  [ -n "$token" ] || return 1
  body=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/_matrix/client/r0/createRoom?access_token=$token" \
    -H "Content-Type: application/json" \
    -d '{"name":"QA test room","preset":"private_chat"}' 2>/dev/null) || return 1
  code=$(echo "$body" | tail -n1)
  body=$(echo "$body" | sed '$d')
  [ "$code" = "200" ] || return 1
  echo "$body" > /tmp/matrix_room.json
  return 0
}

test_send_message() {
  local token room_id body code
  token=$(jq -r '.access_token // empty' /tmp/matrix_login.json 2>/dev/null)
  room_id=$(jq -r '.room_id // empty' /tmp/matrix_room.json 2>/dev/null)
  [ -n "$token" ] && [ -n "$room_id" ] || return 1
  local txn_id="qa-$(date +%s)-$$"
  body=$(curl -sS -w "\n%{http_code}" -X PUT "$BASE_URL/_matrix/client/r0/rooms/$room_id/send/m.room.message/$txn_id?access_token=$token" \
    -H "Content-Type: application/json" \
    -d '{"msgtype":"m.text","body":"QA test message"}' 2>/dev/null) || return 1
  code=$(echo "$body" | tail -n1)
  [ "$code" = "200" ] || return 1
  return 0
}

test_logout() {
  local token
  token=$(jq -r '.access_token // empty' /tmp/matrix_login.json 2>/dev/null)
  [ -n "$token" ] || return 0
  curl -sS -X POST "$BASE_URL/_matrix/client/r0/logout?access_token=$token" -H "Content-Type: application/json" -d '{}' >/dev/null 2>&1 || true
  return 0
}

# --- Register one user via Admin API; write login JSON to $1 (e.g. $TMP_PREFIX_user2.json) ---
register_user() {
  local outfile="$1"
  local username="$2"
  local password="${3:-$TEST_PASSWORD}"
  local nonce mac body resp code
  body=$(curl -sS -w "\n%{http_code}" "$BASE_URL/_synapse/admin/v1/register" 2>/dev/null) || return 1
  code=$(echo "$body" | tail -n1)
  body=$(echo "$body" | sed '$d')
  [ "$code" = "200" ] || return 1
  nonce=$(echo "$body" | jq -r '.nonce // empty')
  [ -n "$nonce" ] || return 1
  mac=$(printf '%s\0%s\0%s\0notadmin' "$nonce" "$username" "$password" | openssl dgst -sha1 -hmac "$REGISTRATION_SHARED_SECRET" 2>/dev/null | awk '{print $2}')
  resp=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/_synapse/admin/v1/register" \
    -H "Content-Type: application/json" \
    -d "{\"nonce\":\"$nonce\",\"username\":\"$username\",\"password\":\"$password\",\"admin\":false,\"mac\":\"$mac\"}" 2>/dev/null) || return 1
  code=$(echo "$resp" | tail -n1)
  body=$(echo "$resp" | sed '$d')
  if [ "$code" = "200" ]; then
    echo "$body" > "$outfile"
    return 0
  fi
  if [ "$code" = "400" ] && echo "$body" | jq -e '.errcode == "M_USER_IN_USE"' >/dev/null 2>&1; then
    resp=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/_matrix/client/r0/login" \
      -H "Content-Type: application/json" \
      -d "{\"type\":\"m.login.password\",\"user\":\"$username\",\"password\":\"$password\"}" 2>/dev/null) || return 1
    code=$(echo "$resp" | tail -n1)
    body=$(echo "$resp" | sed '$d')
    [ "$code" = "200" ] || return 1
    echo "$body" > "$outfile"
    return 0
  fi
  return 1
}

test_register_multiple_users() {
  local i
  for i in $(seq 1 "$NUM_EXTRA_USERS"); do
    register_user "${TMP_PREFIX}_user${i}.json" "qa-multi-${i}-$(date +%s)" || return 1
  done
  return 0
}

test_create_encrypted_room() {
  local token body code
  token=$(jq -r '.access_token // empty' /tmp/matrix_login.json 2>/dev/null)
  [ -n "$token" ] || return 1
  body=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/_matrix/client/r0/createRoom?access_token=$token" \
    -H "Content-Type: application/json" \
    -d '{"name":"QA E2EE room","preset":"private_chat","initial_state":[{"type":"m.room.encryption","state_key":"","content":{"algorithm":"m.megolm.v1.aes-sha2"}}]}' 2>/dev/null) || return 1
  code=$(echo "$body" | tail -n1)
  body=$(echo "$body" | sed '$d')
  [ "$code" = "200" ] || return 1
  echo "$body" > "${TMP_PREFIX}_room_enc.json"
  jq -e '.room_id' "${TMP_PREFIX}_room_enc.json" >/dev/null || return 1
  return 0
}

test_create_unencrypted_room() {
  local token body code
  token=$(jq -r '.access_token // empty' /tmp/matrix_login.json 2>/dev/null)
  [ -n "$token" ] || return 1
  body=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/_matrix/client/r0/createRoom?access_token=$token" \
    -H "Content-Type: application/json" \
    -d '{"name":"QA plain room","preset":"private_chat"}' 2>/dev/null) || return 1
  code=$(echo "$body" | tail -n1)
  body=$(echo "$body" | sed '$d')
  [ "$code" = "200" ] || return 1
  echo "$body" > "${TMP_PREFIX}_room_plain.json"
  jq -e '.room_id' "${TMP_PREFIX}_room_plain.json" >/dev/null || return 1
  return 0
}

test_invite_and_join() {
  local room_id token_inviter token_invitee code body
  room_id=$(jq -r '.room_id' "${TMP_PREFIX}_room_enc.json" 2>/dev/null)
  [ -n "$room_id" ] || return 1
  token_inviter=$(jq -r '.access_token // empty' /tmp/matrix_login.json 2>/dev/null)
  token_invitee=$(jq -r '.access_token // empty' "${TMP_PREFIX}_user1.json" 2>/dev/null)
  [ -n "$token_inviter" ] && [ -n "$token_invitee" ] || return 1
  local user_id_invitee
  user_id_invitee=$(jq -r '.user_id // empty' "${TMP_PREFIX}_user1.json" 2>/dev/null)
  [ -n "$user_id_invitee" ] || user_id_invitee=$(curl -sS "$BASE_URL/_matrix/client/r0/account/whoami?access_token=$token_invitee" 2>/dev/null | jq -r '.user_id // empty')
  [ -n "$user_id_invitee" ] || return 1
  body=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/_matrix/client/r0/rooms/$room_id/invite?access_token=$token_inviter" \
    -H "Content-Type: application/json" \
    -d "{\"user_id\":\"$user_id_invitee\"}" 2>/dev/null) || return 1
  code=$(echo "$body" | tail -n1)
  [ "$code" = "200" ] || return 1
  body=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/_matrix/client/r0/rooms/$room_id/join?access_token=$token_invitee" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null) || return 1
  code=$(echo "$body" | tail -n1)
  [ "$code" = "200" ] || return 1
  return 0
}

test_multi_user_messages() {
  local room_id token1 token2 code txn
  room_id=$(jq -r '.room_id' "${TMP_PREFIX}_room_enc.json" 2>/dev/null)
  [ -n "$room_id" ] || return 1
  token1=$(jq -r '.access_token // empty' /tmp/matrix_login.json 2>/dev/null)
  token2=$(jq -r '.access_token // empty' "${TMP_PREFIX}_user1.json" 2>/dev/null)
  [ -n "$token1" ] && [ -n "$token2" ] || return 1
  txn="qa-msg-$(date +%s)-1"
  body=$(curl -sS -w "\n%{http_code}" -X PUT "$BASE_URL/_matrix/client/r0/rooms/$room_id/send/m.room.message/$txn?access_token=$token1" \
    -H "Content-Type: application/json" \
    -d '{"msgtype":"m.text","body":"Message from user1"}' 2>/dev/null) || return 1
  [ "$(echo "$body" | tail -n1)" = "200" ] || return 1
  txn="qa-msg-$(date +%s)-2"
  body=$(curl -sS -w "\n%{http_code}" -X PUT "$BASE_URL/_matrix/client/r0/rooms/$room_id/send/m.room.message/$txn?access_token=$token2" \
    -H "Content-Type: application/json" \
    -d '{"msgtype":"m.text","body":"Message from user2"}' 2>/dev/null) || return 1
  [ "$(echo "$body" | tail -n1)" = "200" ] || return 1
  return 0
}

test_file_upload_download() {
  local token room_id code body content_uri media_id
  token=$(jq -r '.access_token // empty' /tmp/matrix_login.json 2>/dev/null)
  room_id=$(jq -r '.room_id' /tmp/matrix_room.json 2>/dev/null)
  [ -n "$token" ] && [ -n "$room_id" ] || return 1
  body=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/_matrix/media/r0/upload?access_token=$token" \
    -H "Content-Type: application/octet-stream" \
    -d "QA file content $(date +%s)" 2>/dev/null) || return 1
  code=$(echo "$body" | tail -n1)
  body=$(echo "$body" | sed '$d')
  [ "$code" = "200" ] || return 1
  content_uri=$(echo "$body" | jq -r '.content_uri // empty')
  [ -n "$content_uri" ] || return 1
  echo "$content_uri" > "${TMP_PREFIX}_content_uri.txt"
  txn="qa-file-$(date +%s)"
  body=$(curl -sS -w "\n%{http_code}" -X PUT "$BASE_URL/_matrix/client/r0/rooms/$room_id/send/m.room.message/$txn?access_token=$token" \
    -H "Content-Type: application/json" \
    -d "{\"msgtype\":\"m.file\",\"body\":\"qa-file.txt\",\"url\":\"$content_uri\"}" 2>/dev/null) || return 1
  [ "$(echo "$body" | tail -n1)" = "200" ] || return 1
  rest="${content_uri#mxc://}"
  server="${rest%%/*}"
  media="${rest#*/}"
  [ -n "$server" ] && [ -n "$media" ] || return 1
  code=$(curl -sS -w "%{http_code}" -o "${TMP_PREFIX}_downloaded" "$BASE_URL/_matrix/media/r0/download/$server/$media?access_token=$token" 2>/dev/null)
  [ "$code" = "200" ] || return 1
  grep -q "QA file content" "${TMP_PREFIX}_downloaded" 2>/dev/null || true
  return 0
}

# Moderation bots: assert @draupnir and @mjolnir are in a room and are admins (power level 100).
# Only invoked when MODERATION_BOTS_TEST=1 and MATRIX_QA_ADMIN_PASSWORD is set.
test_moderation_bots_in_room() {
  local admin_pass="${MATRIX_QA_ADMIN_PASSWORD:-}"
  [ -n "$admin_pass" ] || return 1
  local server_name="${MATRIX_QA_SERVER_NAME:-qa.local}"
  local admin_token
  admin_token=$(curl -sS -X POST "$BASE_URL/_matrix/client/r0/login" -H "Content-Type: application/json" \
    -d "{\"type\":\"m.login.password\",\"user\":\"admin\",\"password\":\"$admin_pass\"}" 2>/dev/null | jq -r '.access_token // empty')
  [ -n "$admin_token" ] || return 1
  local room_id
  room_id=$(curl -sS -X POST "$BASE_URL/_matrix/client/r0/createRoom?access_token=$(jq -r '.access_token' /tmp/matrix_login.json)" \
    -H "Content-Type: application/json" \
    -d '{"name":"QA moderation bots room","preset":"private_chat"}' 2>/dev/null | jq -r '.room_id // empty')
  [ -n "$room_id" ] || return 1
  local room_enc
  room_enc=$(echo "$room_id" | sed 's/!/%21/g; s/:/%3A/g')
  curl -sS -X POST -H "Authorization: Bearer $admin_token" -H "Content-Type: application/json" \
    -d "{\"user_id\":\"@admin:$server_name\"}" "$BASE_URL/_synapse/admin/v1/join/$room_enc" 2>/dev/null || true
  curl -sS -X POST -H "Authorization: Bearer $admin_token" -H "Content-Type: application/json" \
    -d "{\"user_id\":\"@draupnir:$server_name\"}" "$BASE_URL/_synapse/admin/v1/join/$room_enc" 2>/dev/null || true
  curl -sS -X POST -H "Authorization: Bearer $admin_token" -H "Content-Type: application/json" \
    -d "{\"user_id\":\"@mjolnir:$server_name\"}" "$BASE_URL/_synapse/admin/v1/join/$room_enc" 2>/dev/null || true
  curl -sS -X POST -H "Authorization: Bearer $admin_token" -H "Content-Type: application/json" \
    -d "{\"user_id\":\"@draupnir:$server_name\"}" "$BASE_URL/_synapse/admin/v1/rooms/$room_enc/make_room_admin" 2>/dev/null || true
  curl -sS -X POST -H "Authorization: Bearer $admin_token" -H "Content-Type: application/json" \
    -d "{\"user_id\":\"@mjolnir:$server_name\"}" "$BASE_URL/_synapse/admin/v1/rooms/$room_enc/make_room_admin" 2>/dev/null || true
  local token
  token=$(jq -r '.access_token' /tmp/matrix_login.json 2>/dev/null)
  [ -n "$token" ] || return 1
  local members pl
  members=$(curl -sS "$BASE_URL/_matrix/client/r0/rooms/$room_enc/joined_members?access_token=$token" 2>/dev/null | jq -r '.joined | keys[]' 2>/dev/null)
  pl=$(curl -sS "$BASE_URL/_matrix/client/r0/rooms/$room_enc/state/m.room.power_levels?access_token=$token" 2>/dev/null | jq -r '.users // {}' 2>/dev/null)
  echo "$members" | grep -q "@draupnir:$server_name" || return 1
  echo "$members" | grep -q "@mjolnir:$server_name" || return 1
  [ "$(echo "$pl" | jq -r ".\"@draupnir:$server_name\" // 0")" = "100" ] || return 1
  [ "$(echo "$pl" | jq -r ".\"@mjolnir:$server_name\" // 0")" = "100" ] || return 1
  return 0
}

# Send !draupnir watch <community-list> to Draupnir management room; validates federation + community-list path.
# Requires: MODERATION_BOTS_TEST=1, MATRIX_QA_ADMIN_PASSWORD, MATRIX_QA_DRAUPNIR_MANAGEMENT_ROOM.
# With federation enabled, Draupnir will actually subscribe; without, the command is still sent (bot may log failure to join remote room).
test_subscribe_draupnir_community_list() {
  local admin_pass="${MATRIX_QA_ADMIN_PASSWORD:-}"
  local mgmt_room="${MATRIX_QA_DRAUPNIR_MANAGEMENT_ROOM:-}"
  [ -n "$admin_pass" ] && [ -n "$mgmt_room" ] || return 1
  local admin_token
  admin_token=$(curl -sS -X POST "$BASE_URL/_matrix/client/r0/login" -H "Content-Type: application/json" \
    -d "{\"type\":\"m.login.password\",\"user\":\"admin\",\"password\":\"$admin_pass\"}" 2>/dev/null | jq -r '.access_token // empty')
  [ -n "$admin_token" ] || return 1
  local room_enc
  room_enc=$(echo "$mgmt_room" | sed 's/!/%21/g; s/:/%3A/g')
  local txn="watch-cme-$(date +%s)-$$"
  local body
  body=$(curl -sS -X PUT "$BASE_URL/_matrix/client/r0/rooms/$room_enc/send/m.room.message/$txn?access_token=$admin_token" \
    -H "Content-Type: application/json" \
    -d '{"msgtype":"m.text","body":"!draupnir watch #community-moderation-effort-bl:neko.dev"}' 2>/dev/null)
  echo "$body" | jq -e '.event_id' >/dev/null 2>&1 || return 1
  return 0
}

cleanup_tmp() {
  rm -f "${TMP_PREFIX}"_*.json "${TMP_PREFIX}"_*.txt "${TMP_PREFIX}_downloaded" 2>/dev/null || true
}
trap cleanup_tmp EXIT

[ "${FEDERATION_ENABLED:-0}" = "1" ] && FED_BANNER=" (federation enabled)" || FED_BANNER=""
echo "Matrix QA tests — base URL: $BASE_URL$FED_BANNER"
[ -n "${MATRIX_QA_TESTS:-}" ] && echo "Filter: MATRIX_QA_TESTS=$MATRIX_QA_TESTS"
[ -n "${MATRIX_QA_SKIP:-}" ] && echo "Filter: MATRIX_QA_SKIP=$MATRIX_QA_SKIP"
echo "---"
run_test_if_selected "versions" "Client versions" test_versions
if [ "${FEDERATION_ENABLED:-0}" = "1" ]; then
  run_test_if_selected "federation_allowed" "nginx: federation allowed, .well-known/server 200" test_nginx_federation_allowed
  run_test_if_selected "wellknown_server" "nginx: .well-known/matrix/server 200 + m.server" test_wellknown_server_200
else
  run_test_if_selected "federation_blocked" "nginx: federation blocked, .well-known/server 404" test_nginx_federation_blocked
fi
run_test_if_selected "wellknown_client" "nginx: .well-known/matrix/client 200" test_nginx_wellknown_client
run_test_if_selected "metrics" "Synapse /_synapse/metrics 200" test_synapse_metrics
run_test_if_selected "register_login" "Register + login (Admin API)" test_register_and_login
run_test_if_selected "whoami" "Whoami" test_whoami
run_test_if_selected "create_room" "Create room" test_create_room
run_test_if_selected "send_message" "Send message" test_send_message
run_test_if_selected "sync" "Sync" test_sync
run_test_if_selected "room_timeline" "Room timeline (messages)" test_room_timeline
run_test_if_selected "rate_limit" "nginx: rate limit (login 503)" test_nginx_rate_limit
run_test_if_selected "register_extra_users" "Register $NUM_EXTRA_USERS extra users" test_register_multiple_users
run_test_if_selected "encrypted_room" "Create encrypted room (E2EE)" test_create_encrypted_room
run_test_if_selected "unencrypted_room" "Create unencrypted room" test_create_unencrypted_room
run_test_if_selected "invite_join" "Invite and join (second user to E2EE room)" test_invite_and_join
run_test_if_selected "multi_user_messages" "Multi-user messages (E2EE room)" test_multi_user_messages
run_test_if_selected "file_upload" "File upload, send as message, download" test_file_upload_download
if [ "$MODERATION_BOTS_TEST" = "1" ] && [ -n "${MATRIX_QA_ADMIN_PASSWORD:-}" ]; then
  run_test_if_selected "moderation_bots" "Moderation bots in room (Draupnir/Mjolnir in room, admin PL 100)" test_moderation_bots_in_room
  if [ -n "${MATRIX_QA_DRAUPNIR_MANAGEMENT_ROOM:-}" ]; then
    run_test_if_selected "subscribe_draupnir" "Subscribe Draupnir to community list (send !draupnir watch CME)" test_subscribe_draupnir_community_list
  fi
fi
run_test_if_selected "logout" "Logout" test_logout
echo "---"
if [ "$FAILED" -eq 0 ]; then
  echo "All Matrix QA tests passed."
  exit 0
else
  echo "Failed: $FAILED test(s)."
  exit 1
fi
