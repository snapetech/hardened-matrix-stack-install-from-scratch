#!/usr/bin/env bash
# Run Matrix QA tests from your machine against a Synapse instance (Kubernetes NodePort or port-forward).
# Usage:
#   ./k8s-qa/run-matrix-qa-tests.sh [BASE_URL]
#   MATRIX_BASE_URL=http://localhost:30048 ./k8s-qa/run-matrix-qa-tests.sh
#
# Default BASE_URL: http://localhost:30048 (NodePort for matrix-qa/synapse, or after port-forward).
# Requires: curl, jq, openssl.
set -e

BASE_URL="${MATRIX_BASE_URL:-http://localhost:30048}"
BASE_URL="${1:-$BASE_URL}"
BASE_URL="${BASE_URL%/}"
REGISTRATION_SHARED_SECRET="${MATRIX_REGISTRATION_SHARED_SECRET:-qa-test-registration-secret}"
TEST_USER="qa-test-user-$(date +%s)"
TEST_PASSWORD="qa-test-password"
FAILED=0

run_test() {
  local name="$1"
  shift
  if "$@"; then
    echo "  OK: $name"
    return 0
  else
    echo "  FAIL: $name"
    FAILED=$((FAILED + 1))
    return 1
  fi
}

test_versions() {
  local r
  r=$(curl -sS -w "%{http_code}" -o /tmp/matrix_versions.json "$BASE_URL/_matrix/client/versions" 2>/dev/null)
  [ "$r" = "200" ] || return 1
  if command -v jq &>/dev/null; then
    jq -e '.versions | length > 0' /tmp/matrix_versions.json >/dev/null || return 1
  else
    grep -q "r0" /tmp/matrix_versions.json || return 1
  fi
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

echo "Matrix QA tests — base URL: $BASE_URL"
echo "---"
run_test "Client versions" test_versions
run_test "Register + login (Admin API)" test_register_and_login
run_test "Create room" test_create_room
run_test "Send message" test_send_message
run_test "Logout" test_logout
echo "---"
if [ "$FAILED" -eq 0 ]; then
  echo "All Matrix QA tests passed."
  exit 0
else
  echo "Failed: $FAILED test(s)."
  exit 1
fi
