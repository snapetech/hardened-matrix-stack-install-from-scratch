#!/usr/bin/env bash
# Run from your machine (when you can SSH in). Whitelists your IP in fail2ban so you
# don't get locked out again. Uses sudo from keyring.
# Usage: ./fail2ban-whitelist-ssh-client-remote.sh [user@host]
set -e
REMOTE="${1:-lukano@timeways.net}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MY_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || true)
[[ -z "$MY_IP" ]] && { echo "Could not get your IP (ifconfig.me)." >&2; exit 1; }
PASS=$(secret-tool lookup service sudo-remote user "$REMOTE" 2>/dev/null) || {
  echo "Failed to get password from keyring (service=sudo-remote, user=$REMOTE)." >&2
  exit 1
}
( printf '%s\n' "$PASS"; cat "$SCRIPT_DIR/fail2ban-whitelist-ssh-client.sh" ) | ssh "$REMOTE" "sudo -S -p '' bash -s '$MY_IP'"
exit $?
