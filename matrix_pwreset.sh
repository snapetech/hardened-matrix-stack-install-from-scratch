#!/bin/bash
# matrix_pwreset.sh — reset a Matrix/Synapse user password
# Usage: sudo bash matrix_pwreset.sh <localpart> [new_password]
# If new_password is omitted, a random one is generated and printed.
# Installed on server at: /usr/local/sbin/matrix_pwreset.sh
set -e

MATRIX_USER="${1:?Usage: $0 <localpart> [new_password]}"
NEWPASS="$2"
CFG="/etc/matrix-synapse/homeserver.yaml"
CFGD="/etc/matrix-synapse/conf.d"

# Resolve server name
SERVER=$(grep '^server_name:' "${CFGD}/server_name.yaml" 2>/dev/null | awk '{print $2}' | tr -d '"')
[ -z "$SERVER" ] && SERVER=$(grep '^server_name:' "$CFG" | awk '{print $2}' | tr -d '"')
FULL_USER="@${MATRIX_USER}:${SERVER}"

# Verify user exists
EXISTS=$(sudo -u postgres psql synapse -tAc "SELECT COUNT(*) FROM users WHERE name='${FULL_USER}';")
if [ "$EXISTS" -eq 0 ]; then
  echo "ERROR: User ${FULL_USER} not found"
  echo "Close matches:"
  sudo -u postgres psql synapse -c "SELECT name FROM users WHERE name LIKE '%${MATRIX_USER}%';"
  exit 1
fi

# Generate random password if not provided
if [ -z "$NEWPASS" ]; then
  NEWPASS=$(python3 -c "import secrets,string; print(''.join(secrets.choice(string.ascii_letters+string.digits+'!@#%^&*') for _ in range(20)))")
fi

# Generate bcrypt hash via Synapse's own tool
HASHBIN=$(find /opt/venvs/matrix-synapse/bin /usr/bin -name hash_password 2>/dev/null | head -1)
HASH=$(echo "$NEWPASS" | "$HASHBIN" -c "$CFG" 2>/dev/null)

# Update the DB
sudo -u postgres psql synapse -c "UPDATE users SET password_hash='${HASH}' WHERE name='${FULL_USER}';"

# Invalidate existing sessions so old password can't be reused
sudo -u postgres psql synapse -c "DELETE FROM access_tokens WHERE user_id='${FULL_USER}';" 2>/dev/null || true

echo ""
echo "Password reset complete."
echo "  User:     ${FULL_USER}"
echo "  Password: ${NEWPASS}"
