#!/bin/bash
# Apply nginx fix: allow Docker bridge for /_synapse/admin so Mjolnir can call admin API (fix 403).
#
# Run once (do not retry on failure; fix cause first to avoid fail2ban):
#   ./run-remote-sudo.sh lukano@timeways.net apply-mjolnir-fixes-remote.sh
set -e
echo "[1] Update nginx synapse-hardening snippet (allow Docker bridge for /_synapse/admin)..."
if [ -f /home/lukano/nginx-synapse-hardening.conf ]; then
  cp /home/lukano/nginx-synapse-hardening.conf /etc/nginx/snippets/synapse-hardening.conf
  echo "  Updated /etc/nginx/snippets/synapse-hardening.conf"
else
  echo "  (File not found at /home/lukano/nginx-synapse-hardening.conf; copy it first)"
fi

echo "[2] Reload nginx and restart Mjolnir..."
nginx -t && systemctl reload nginx
docker restart mjolnir 2>/dev/null || true
echo "Done. Check Mjolnir logs for 403 on admin API."
