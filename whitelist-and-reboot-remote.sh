#!/usr/bin/env bash
# When you can SSH in again: whitelist your IP in fail2ban, then reboot the server.
# Usage: ./whitelist-and-reboot-remote.sh [user@host]
# After reboot, wait ~2 min then run ./fail2ban-whitelist-ssh-client-remote.sh again
# from your machine so your IP is in ignoreip before you hit maxretry.
set -e
REMOTE="${1:-lukano@timeways.net}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "Step 1: Whitelist your IP in fail2ban on $REMOTE..."
"$SCRIPT_DIR/fail2ban-whitelist-ssh-client-remote.sh" "$REMOTE"
echo ""
echo "Step 2: Reboot the server (systemctl reboot)..."
PASS=$(secret-tool lookup service sudo-remote user "$REMOTE" 2>/dev/null) || {
  echo "Failed to get password from keyring." >&2
  exit 1
}
( printf '%s\n' "$PASS"; echo "systemctl reboot" ) | ssh "$REMOTE" 'sudo -S -p "" bash -s'
echo "Reboot sent. Server will come back in 1–2 min."
