#!/usr/bin/env bash
# Run on the server with sudo. IP from first argument, or stdin, or SSH_CONNECTION.
# Adds the IP to fail2ban ignoreip for sshd, unbans it, reloads fail2ban.
set -e
CLIENT_IP="$1"
if [[ -z "$CLIENT_IP" ]]; then
  read -r CLIENT_IP 2>/dev/null || true
fi
if [[ -z "$CLIENT_IP" ]]; then
  CLIENT_IP="${SSH_CONNECTION%% *}"
fi
if [[ -z "$CLIENT_IP" ]]; then
  echo "Usage: pass IP as first arg or stdin (e.g. echo YOUR_IP | sudo bash this.sh)." >&2
  exit 1
fi
echo "Whitelisting SSH client IP: $CLIENT_IP"
# Current ignoreip for sshd (may be empty or 127.0.0.1/8 ::1)
CURRENT=$(fail2ban-client get sshd ignoreip 2>/dev/null || true)
if [[ -z "$CURRENT" ]]; then
  CURRENT="127.0.0.1/8 ::1"
fi
# Avoid duplicate
if echo "$CURRENT" | grep -qE "(^| )$CLIENT_IP( |$)"; then
  echo "IP $CLIENT_IP already in ignoreip."
else
  NEW_IGNORE="$CURRENT $CLIENT_IP"
  mkdir -p /etc/fail2ban/jail.d
  cat > /etc/fail2ban/jail.d/99-ssh-admin-ignoreip.conf << EOF
# Added by fail2ban-whitelist-ssh-client.sh - do not remove if you need this IP whitelisted
[sshd]
ignoreip = $NEW_IGNORE
EOF
  echo "Wrote /etc/fail2ban/jail.d/99-ssh-admin-ignoreip.conf"
fi
# Unban this IP from sshd jail if banned
fail2ban-client set sshd unbanip "$CLIENT_IP" 2>/dev/null || true
fail2ban-client reload
echo "Done. $CLIENT_IP is whitelisted and unbanned."
