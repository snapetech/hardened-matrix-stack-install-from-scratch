#!/usr/bin/env bash
# From your machine: get your IP, add it to the server's nginx allow list for /_synapse/admin,
# then you can run the load test from local without a tunnel. Uses sudo from keyring.
# Usage: ./allow-admin-from-ssh-client-remote.sh [user@host]
set -e
REMOTE="${1:-lukano@timeways.net}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MY_IP=$(curl -s ifconfig.me)
[[ -z "$MY_IP" ]] && { echo "Could not get your IP (ifconfig.me)." >&2; exit 1; }
PASS=$(secret-tool lookup service sudo-remote user "$REMOTE" 2>/dev/null) || {
  echo "Failed to get password from keyring (service=sudo-remote, user=$REMOTE)." >&2
  exit 1
}
scp -q "$SCRIPT_DIR/allow-admin-from-ssh-client.sh" "$REMOTE:/tmp/allow_admin_from_ssh_client.sh"
( printf '%s\n' "$PASS"; echo "$MY_IP" ) | ssh "$REMOTE" 'sudo -S -p "" bash /tmp/allow_admin_from_ssh_client.sh'
ssh "$REMOTE" 'rm -f /tmp/allow_admin_from_ssh_client.sh'
exit $?
