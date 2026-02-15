#!/usr/bin/env bash
# Run full E2E QA: API + multi-user + file tests, then (if LiveKit URLs set) headless call tests.
# Usage:
#   ./k8s-qa/run-e2e-qa.sh
#   MATRIX_BASE_URL=http://localhost:30048 LIVEKIT_WS_URL=ws://localhost:30049 LIVEKIT_JWT_URL=http://localhost:30050 ./k8s-qa/run-e2e-qa.sh
#
# Requires: curl, jq, openssl. For call tests: Python 3.10+, load-test deps (see load-test/requirements.txt).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE_URL="${MATRIX_BASE_URL:-http://localhost:30048}"
BASE_URL="${BASE_URL%/}"
SERVER_NAME="${MATRIX_QA_SERVER_NAME:-qa.local}"
REGISTRATION_SHARED_SECRET="${MATRIX_REGISTRATION_SHARED_SECRET:-qa-test-registration-secret}"
LIVEKIT_WS_URL="${LIVEKIT_WS_URL:-}"
LIVEKIT_JWT_URL="${LIVEKIT_JWT_URL:-}"
CALL_DURATION="${MATRIX_QA_CALL_DURATION:-25}"
CALL_PARTICIPANTS_GROUP1="${MATRIX_QA_CALL_PARTICIPANTS_3:-3}"
CALL_PARTICIPANTS_GROUP2="${MATRIX_QA_CALL_PARTICIPANTS_5:-5}"
FAILED=0

run_phase() {
  local name="$1"
  shift
  echo ""
  echo "=== $name ==="
  if "$@"; then
    echo "  Phase OK: $name"
    return 0
  else
    echo "  Phase FAIL: $name"
    FAILED=$((FAILED + 1))
    return 1
  fi
}

# --- Phase 1: API + multi-user + file tests ---
run_phase "API and multi-user tests" "$SCRIPT_DIR/run-matrix-qa-tests.sh" "$BASE_URL"

# --- Phase 2: Call tests (optional, when LiveKit URLs are set) ---
if [ -n "$LIVEKIT_WS_URL" ] && [ -n "$LIVEKIT_JWT_URL" ]; then
  LIVEKIT_JWT_URL="${LIVEKIT_JWT_URL%/}"
  QA_CONFIG="$REPO_ROOT/load-test/config-qa-e2e.yaml"
  QA_USERS="$REPO_ROOT/load-test/test_users_qa_e2e.json"
  QA_ROOM_FILE="$REPO_ROOT/load-test/test_room_id_qa_e2e.txt"
  rm -f "$QA_ROOM_FILE" "$QA_USERS" 2>/dev/null || true

  # Register one admin user (shared secret, admin=true) to use Admin API for creating test users
  ADMIN_USER="qa-admin-$(date +%s)"
  ADMIN_PASS="qa-admin-pass-$$"
  body=$(curl -sS -w "\n%{http_code}" "$BASE_URL/_synapse/admin/v1/register" 2>/dev/null) || true
  code=$(echo "$body" | tail -n1)
  body=$(echo "$body" | sed '$d')
  if [ "$code" != "200" ]; then
    echo "  Skip call tests: could not get registration nonce ($code)"
  else
    nonce=$(echo "$body" | jq -r '.nonce // empty')
    if [ -n "$nonce" ]; then
      mac=$(printf '%s\0%s\0%s\0admin' "$nonce" "$ADMIN_USER" "$ADMIN_PASS" | openssl dgst -sha1 -hmac "$REGISTRATION_SHARED_SECRET" 2>/dev/null | awk '{print $2}')
      resp=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/_synapse/admin/v1/register" \
        -H "Content-Type: application/json" \
        -d "{\"nonce\":\"$nonce\",\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\",\"admin\":true,\"mac\":\"$mac\"}" 2>/dev/null) || true
      code=$(echo "$resp" | tail -n1)
      body=$(echo "$resp" | sed '$d')
      if [ "$code" = "200" ]; then
        ADMIN_TOKEN=$(echo "$body" | jq -r '.access_token // empty')
        ADMIN_USER_ID=$(echo "$body" | jq -r '.user_id // empty')
        if [ -z "$ADMIN_USER_ID" ]; then
          ADMIN_USER_ID="@${ADMIN_USER}:${SERVER_NAME}"
        fi
      fi
    fi
  fi

  if [ -n "$ADMIN_TOKEN" ] && [ -n "$ADMIN_USER_ID" ]; then
    # Write QA config for load-test
    cat > "$QA_CONFIG" << EOF
server_url: "$BASE_URL"
server_name: "$SERVER_NAME"
admin_user_id: "$ADMIN_USER_ID"
admin_access_token: "$ADMIN_TOKEN"
admin_api_token: "$ADMIN_TOKEN"
livekit_ws_url: "$LIVEKIT_WS_URL"
livekit_jwt_url: "$LIVEKIT_JWT_URL"
test_users_file: "test_users_qa_e2e.json"
participants: $CALL_PARTICIPANTS_GROUP2
duration_seconds: $CALL_DURATION
safety:
  load1_max: 20
  consecutive_errors_max: 10
EOF
    cd "$REPO_ROOT/load-test"
    if [ ! -d ".venv" ]; then
      echo "  Creating load-test venv and installing deps..."
      python3 -m venv .venv
      .venv/bin/pip install -q -r requirements.txt
    fi
    export PATH="$REPO_ROOT/load-test/.venv/bin:$PATH"
    if .venv/bin/python scripts/create_test_users.py --config config-qa-e2e.yaml --participants "$CALL_PARTICIPANTS_GROUP2" --force 2>/dev/null; then
      if [ -f test_room_id.txt ]; then
        cp test_room_id.txt "$QA_ROOM_FILE"
        export TEST_ROOM_ID="$(cat test_room_id.txt)"
      fi
      echo ""
      echo "=== Call test: group video (${CALL_PARTICIPANTS_GROUP2} participants, ${CALL_DURATION}s) ==="
      if .venv/bin/python scripts/run_load_test.py --config "$QA_CONFIG" --no-create-users --duration "$CALL_DURATION" --participants "$CALL_PARTICIPANTS_GROUP2" 2>&1; then
        echo "  OK: Group call (${CALL_PARTICIPANTS_GROUP2} users)"
      else
        echo "  FAIL: Group call (exit $?)"
        FAILED=$((FAILED + 1))
      fi
      # Optional: 3-user group call
      if [ "$CALL_PARTICIPANTS_GROUP1" != "$CALL_PARTICIPANTS_GROUP2" ] && [ "$CALL_PARTICIPANTS_GROUP1" -ge 2 ]; then
        echo ""
        echo "=== Call test: group video (${CALL_PARTICIPANTS_GROUP1} participants, ${CALL_DURATION}s) ==="
        if .venv/bin/python scripts/run_load_test.py --config "$QA_CONFIG" --no-create-users --duration "$CALL_DURATION" --participants "$CALL_PARTICIPANTS_GROUP1" 2>&1; then
          echo "  OK: Group call (${CALL_PARTICIPANTS_GROUP1} users)"
        else
          echo "  FAIL: Group call ${CALL_PARTICIPANTS_GROUP1} users (exit $?)"
          FAILED=$((FAILED + 1))
        fi
      fi
      # Cleanup: deactivate test users (optional, so next run can recreate)
      .venv/bin/python scripts/remove_test_users.py --config "$QA_CONFIG" --users-file test_users_qa_e2e.json 2>/dev/null || true
    else
      echo "  Skip call tests: create_test_users.py failed"
      FAILED=$((FAILED + 1))
    fi
    rm -f "$QA_CONFIG" "$QA_USERS" "$QA_ROOM_FILE" "$REPO_ROOT/load-test/test_room_id.txt" "$REPO_ROOT/load-test/test_users_qa_e2e.json" 2>/dev/null || true
    cd "$REPO_ROOT"
  else
    echo "  Skip call tests: could not create admin user"
  fi
else
  echo ""
  echo "Call tests skipped (set LIVEKIT_WS_URL and LIVEKIT_JWT_URL to enable)."
fi

echo ""
echo "---"
if [ "$FAILED" -eq 0 ]; then
  echo "All E2E QA phases passed."
  exit 0
else
  echo "Failed: $FAILED phase(s)."
  exit 1
fi
