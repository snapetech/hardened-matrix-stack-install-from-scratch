#!/usr/bin/env bash
# On the server: add your IP to the nginx allow list for /_synapse/admin.
# Run from local: MY_IP=$(curl -s ifconfig.me); (printf '%s\n' "$PASS"; echo "$MY_IP"; cat allow-admin-from-ssh-client.sh) | ssh lukano@timeways.net 'sudo -S bash -s'
# Or use: ./allow-admin-from-ssh-client-remote.sh (wraps the above with run-remote-sudo).
set -e
read -r IP
if [[ -z "$IP" ]]; then
  echo "Pass your IP as first line of stdin (e.g. curl -s ifconfig.me)." >&2
  exit 1
fi
CONF="/etc/nginx/snippets/synapse-hardening.conf"
if ! grep -q "allow $IP;" "$CONF" 2>/dev/null; then
  sed -i "/allow 172.17.0.0\/16;/a \    allow $IP;" "$CONF"
  echo "Added allow $IP to $CONF"
else
  echo "Already allowed: $IP"
fi
nginx -t && systemctl reload nginx
echo "Nginx reloaded. You can run the load test from this machine without a tunnel."
