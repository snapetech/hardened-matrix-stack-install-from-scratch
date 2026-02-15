#!/bin/bash
# Configure certbot to auto-renew and to renew when 21 days or less before expiry.
# Run on server: sudo ./configure-certbot-auto-renew.sh
# Env: MATRIX_DOMAIN, ROOT_DOMAIN (optional; if unset, updates all renewal configs under /etc/letsencrypt/renewal/).
#      RENEW_BEFORE_DAYS (default 21).
set -e
RENEW_BEFORE_DAYS="${RENEW_BEFORE_DAYS:-21}"

if [ -f /lib/systemd/system/certbot.timer ] || [ -f /usr/lib/systemd/system/certbot.timer ]; then
  systemctl enable certbot.timer 2>/dev/null || true
  systemctl start certbot.timer 2>/dev/null || true
  echo "Certbot timer enabled (auto-renew)."
fi

if [ -n "${MATRIX_DOMAIN:-}" ] || [ -n "${ROOT_DOMAIN:-}" ]; then
  CONFS=""
  for dom in "$MATRIX_DOMAIN" "$ROOT_DOMAIN"; do
    [ -z "$dom" ] && continue
    for conf in /etc/letsencrypt/renewal/"$dom".conf /etc/letsencrypt/renewal/"$dom"-*.conf; do
      [ -f "$conf" ] && CONFS="$CONFS $conf"
    done
  done
else
  CONFS=$(echo /etc/letsencrypt/renewal/*.conf 2>/dev/null)
fi

for conf in $CONFS; do
  [ -f "$conf" ] || continue
  if grep -q 'renew_before_expiry' "$conf" 2>/dev/null; then
    sed -i "s/^renew_before_expiry.*/renew_before_expiry = $RENEW_BEFORE_DAYS days/" "$conf"
  else
    sed -i "/\[renewalparams\]/a renew_before_expiry = $RENEW_BEFORE_DAYS days" "$conf" 2>/dev/null || true
  fi
  echo "Set renew_before_expiry = $RENEW_BEFORE_DAYS days in $conf"
done
echo "Certbot will renew when cert has $RENEW_BEFORE_DAYS days or less left."
