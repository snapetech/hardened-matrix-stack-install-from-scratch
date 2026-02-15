#!/bin/bash
# One-off debug: check why temp admin might fail. Run on server with sudo.
set -e
echo "=== need_admin_for_ef paths ==="
for f in /opt/draupnir/config/production.yaml /opt/mjolnir/config/production.yaml /opt/maubot/config.yaml; do
  [ -f "$f" ] && echo "  OK $f" || echo "  MISSING $f"
done
echo ""
echo "=== register_new_matrix_user ==="
for reg in /usr/bin/register_new_matrix_user register_new_matrix_user; do
  if [ -x "$reg" ] 2>/dev/null || command -v "$reg" &>/dev/null; then
    echo "  Found: $reg"
    break
  fi
done
echo ""
echo "=== Current registration_shared_secret (from conf.d) ==="
[ -f /etc/matrix-synapse/conf.d/registration.yaml ] && grep 'registration_shared_secret' /etc/matrix-synapse/conf.d/registration.yaml | sed 's/\(.\{20\}\).*/\1.../' || echo "  (no file)"
echo ""
echo "=== Quick registration test with -k (will create and then deactivate) ==="
CURRENT_REG_SECRET=""
[ -f /etc/matrix-synapse/conf.d/registration.yaml ] && CURRENT_REG_SECRET=$(grep 'registration_shared_secret' /etc/matrix-synapse/conf.d/registration.yaml | sed 's/.*: *//; s/^["'\'']//; s/["\x27].*//; s/[[:space:]].*//; q')
TEST_USER="rotation_debug_$$"
TEST_PASS=$(openssl rand -hex 16)
if [ -z "$CURRENT_REG_SECRET" ]; then
  echo "  No registration_shared_secret in conf.d/registration.yaml; skip test"
elif /usr/bin/register_new_matrix_user -k "$CURRENT_REG_SECRET" http://localhost:8008 -u "$TEST_USER" -p "$TEST_PASS" -a 2>&1; then
  echo "  Registration OK. Login test..."
  MATRIX_DOMAIN="${MATRIX_DOMAIN:-matrix.timeways.net}"
  SERVER_NAME="${SERVER_NAME:-timeways.net}"
  TOKEN=$(curl -sS -X POST "http://127.0.0.1:8008/_matrix/client/r0/login" \
    -H "Host: $MATRIX_DOMAIN" -H "Content-Type: application/json" \
    -d "{\"type\":\"m.login.password\",\"user\":\"$TEST_USER\",\"password\":\"$TEST_PASS\"}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null)
  if [ -n "$TOKEN" ]; then
    echo "  Login OK (token length ${#TOKEN})"
  else
    echo "  Login FAILED (check curl/python3 and Host header)"
  fi
  echo "  Deactivating test user @${TEST_USER}:$SERVER_NAME"
  USER_ID_ENC=$(echo -n "@${TEST_USER}:$SERVER_NAME" | sed 's/@/%40/g; s/:/%3A/g')
  curl -sS -X PUT "http://127.0.0.1:8008/_synapse/admin/v2/users/$USER_ID_ENC" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"deactivated":true}' 2>/dev/null || true
else
  echo "  Registration FAILED (see above)"
fi
echo "=== Done ==="
