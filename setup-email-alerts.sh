#!/bin/bash
# Set up lightweight email alerts on a VPS: msmtp (sendmail shim), fail2ban mail,
# Monit (host/service alerts), and a daily digest via systemd timer.
# Run on server: sudo ./setup-email-alerts.sh
# Env: ALERT_EMAIL (optional; prompted if unset), MSMTP_APP_PASSWORD (optional; prompted if unset),
#       ROUTE_ROOT_MAIL_PROMPT=1 to skip "route root mail?" prompt (default Y).
# For Gmail you must use an App Password (not your normal password). Create one at:
#   https://myaccount.google.com/apppasswords
#   (Help: https://support.google.com/accounts/answer/185833)
set -e

# --- Prompt for email and app password (no defaults, no hardcoded values) ---
if [ -z "${ALERT_EMAIL:-}" ]; then
  echo ""
  echo "Email alerts will be sent to this address (e.g. your Gmail)."
  read -p "Alert email address: " ALERT_EMAIL
  [ -z "$ALERT_EMAIL" ] && { echo "ALERT_EMAIL required." >&2; exit 1; }
fi

if [ -z "${MSMTP_APP_PASSWORD:-}" ]; then
  echo ""
  echo "For Gmail, use an App Password (not your account password)."
  echo "  Create one: https://myaccount.google.com/apppasswords"
  echo "  Help:       https://support.google.com/accounts/answer/185833"
  echo "  (2-Step Verification must be enabled.)"
  read -s -p "SMTP app password (input hidden): " MSMTP_APP_PASSWORD
  echo ""
  [ -z "$MSMTP_APP_PASSWORD" ] && { echo "MSMTP_APP_PASSWORD required." >&2; exit 1; }
fi

# Strip spaces (e.g. user pastes "xxxx xxxx xxxx xxxx")
MSMTP_APP_PASSWORD=$(echo "$MSMTP_APP_PASSWORD" | tr -d '[:space:]')

# --- Optional: route root/postmaster mail to alert email via msmtp ---
ROUTE_ROOT_MAIL=Y
if [ -z "${ROUTE_ROOT_MAIL_PROMPT:-}" ]; then
  read -p "Route root/postmaster mail to alert email (cron, etc.)? [Y/n] " r
  ROUTE_ROOT_MAIL=$(echo "${r:-Y}" | tr '[:upper:]' '[:lower:]')
  [ "$ROUTE_ROOT_MAIL" = "n" ] && ROUTE_ROOT_MAIL=n || ROUTE_ROOT_MAIL=Y
fi

# --- Install packages ---
apt-get update -qq
apt-get install -y -qq msmtp msmtp-mta bsd-mailx monit

# --- msmtp (Gmail) ---
cat > /etc/msmtprc << EOF
defaults
auth on
tls on
tls_starttls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile /var/log/msmtp.log
EOF
[ "$ROUTE_ROOT_MAIL" = "Y" ] && echo "aliases /etc/aliases.msmtp" >> /etc/msmtprc
cat >> /etc/msmtprc << EOF

account default
host smtp.gmail.com
port 587
from ${ALERT_EMAIL}
user ${ALERT_EMAIL}
passwordeval "cat /etc/msmtp.pass"
EOF
printf '%s' "$MSMTP_APP_PASSWORD" > /etc/msmtp.pass
chmod 600 /etc/msmtp.pass /etc/msmtprc
touch /var/log/msmtp.log
chmod 640 /var/log/msmtp.log

if [ "$ROUTE_ROOT_MAIL" = "Y" ]; then
  # So all mail to root (cron, system) goes via msmtp to ALERT_EMAIL
  echo "root: ${ALERT_EMAIL}" > /etc/aliases.msmtp
  echo "postmaster: ${ALERT_EMAIL}" >> /etc/aliases.msmtp
  chmod 644 /etc/aliases.msmtp
  # Also update system /etc/aliases so any tool that reads it forwards root
  if [ -f /etc/aliases ]; then
    if grep -q '^root:' /etc/aliases; then
      sed -i "s|^root:.*|root: ${ALERT_EMAIL}|" /etc/aliases
    else
      echo "root: ${ALERT_EMAIL}" >> /etc/aliases
    fi
    if ! grep -q '^postmaster:' /etc/aliases; then
      echo "postmaster: root" >> /etc/aliases
    fi
    newaliases 2>/dev/null || true
  else
    printf '%s\n' "root: ${ALERT_EMAIL}" "postmaster: root" > /etc/aliases
    newaliases 2>/dev/null || true
  fi
fi

# --- Fail2ban: email on bans ---
mkdir -p /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/99-email-alerts.conf << EOF
# Email on ban (requires msmtp-mta / sendmail)
[DEFAULT]
destemail = ${ALERT_EMAIL}
sender = fail2ban@$(hostname -f 2>/dev/null || echo localhost)
mta = sendmail
action = %(action_mwl)s
EOF
if systemctl is-active --quiet fail2ban 2>/dev/null; then
  systemctl restart fail2ban
  echo "  Fail2ban restarted (email on ban enabled)."
fi

# --- Monit: host + service checks, alert by email ---
# Draupnir/Mjolnir: on this stack they run as Docker containers (no systemd unit).
# Wrapper scripts so Monit can check Docker container state (path cannot take args).
mkdir -p /usr/local/bin
cat > /usr/local/bin/check-docker-draupnir.sh << 'WRAP'
#!/bin/sh
docker inspect -f '{{.State.Running}}' draupnir 2>/dev/null | grep -qx true
WRAP
cat > /usr/local/bin/check-docker-mjolnir.sh << 'WRAP'
#!/bin/sh
docker inspect -f '{{.State.Running}}' mjolnir 2>/dev/null | grep -qx true
WRAP
chmod +x /usr/local/bin/check-docker-draupnir.sh /usr/local/bin/check-docker-mjolnir.sh

# Resource-delta script: only alert when over threshold AND value changed by >= delta since last alert (no repeat alerts for same level)
RESOURCE_DELTA_SCRIPT="/usr/local/bin/monit-resource-delta.sh"
RESOURCE_DELTA_SRC=""
[ -n "${REPO_DIR:-}" ] && [ -f "${REPO_DIR}/monit-resource-delta.sh" ] && RESOURCE_DELTA_SRC="${REPO_DIR}/monit-resource-delta.sh"
[ -z "$RESOURCE_DELTA_SRC" ] && [ -f "$(dirname "$0")/monit-resource-delta.sh" ] && RESOURCE_DELTA_SRC="$(cd "$(dirname "$0")" && pwd)/monit-resource-delta.sh"
[ -z "$RESOURCE_DELTA_SRC" ] && [ -f "./monit-resource-delta.sh" ] && RESOURCE_DELTA_SRC="$(pwd)/monit-resource-delta.sh"
if [ -n "$RESOURCE_DELTA_SRC" ]; then
  cp "$RESOURCE_DELTA_SRC" "$RESOURCE_DELTA_SCRIPT"
  chmod +x "$RESOURCE_DELTA_SCRIPT"
else
  echo "  Warning: monit-resource-delta.sh not found; using built-in Monit resource checks (may repeat alerts)." >&2
fi
mkdir -p /var/lib/monit/resource-state
chmod 700 /var/lib/monit/resource-state 2>/dev/null || true

MONITRC="/etc/monit/monitrc"
# Alerts only on state change (no reminder). Resource checks use delta script so we only alert when value moves by another X%.
cat > "$MONITRC" << EOF
set daemon 60
set mailserver smtp.gmail.com port 587
  username "${ALERT_EMAIL}" password "${MSMTP_APP_PASSWORD}"
  using tlsv12

set alert ${ALERT_EMAIL}

EOF
# Resource checks: only fail (alert) when over threshold AND change since last alert >= delta (memory/swap/disk: %, load: absolute)
if [ -x "$RESOURCE_DELTA_SCRIPT" ]; then
  cat >> "$MONITRC" << 'MONITRES'
check program monit-load with path "/usr/local/bin/monit-resource-delta.sh load 2 0.5"
  if status != 0 then alert

check program monit-memory with path "/usr/local/bin/monit-resource-delta.sh memory 85 10"
  if status != 0 then alert

check program monit-swap with path "/usr/local/bin/monit-resource-delta.sh swap 50 10"
  if status != 0 then alert

check program monit-disk with path "/usr/local/bin/monit-resource-delta.sh disk 85 10"
  if status != 0 then alert

MONITRES
else
  cat >> "$MONITRC" << EOF
check system \$HOST
  if loadavg (1min) > 2 for 5 cycles then alert
  if memory usage > 85% for 5 cycles then alert
  if swap usage > 50% for 5 cycles then alert

check filesystem root with path /
  if space usage > 85% then alert

EOF
fi
cat >> "$MONITRC" << EOF
check program nginx with path "/bin/systemctl is-active --quiet nginx"
  if status != 0 then alert

check program matrix-synapse with path "/bin/systemctl is-active --quiet matrix-synapse"
  if status != 0 then alert

check program draupnir with path "/usr/local/bin/check-docker-draupnir.sh"
  if status != 0 then alert

check program mjolnir with path "/usr/local/bin/check-docker-mjolnir.sh"
  if status != 0 then alert
EOF
chmod 600 "$MONITRC"
monit -t 2>/dev/null || true
systemctl enable --now monit 2>/dev/null || true

# --- Matrix stack healthcheck: periodic restarts + Monit check ---
HEALTHCHECK_SRC=""
[ -n "${REPO_DIR:-}" ] && [ -f "${REPO_DIR}/matrix-stack-healthcheck.sh" ] && HEALTHCHECK_SRC="${REPO_DIR}/matrix-stack-healthcheck.sh"
[ -z "$HEALTHCHECK_SRC" ] && [ -f "$(dirname "$0")/matrix-stack-healthcheck.sh" ] && HEALTHCHECK_SRC="$(cd "$(dirname "$0")" && pwd)/matrix-stack-healthcheck.sh"
[ -z "$HEALTHCHECK_SRC" ] && [ -f "./matrix-stack-healthcheck.sh" ] && HEALTHCHECK_SRC="$(pwd)/matrix-stack-healthcheck.sh"
if [ -n "$HEALTHCHECK_SRC" ]; then
  cp "$HEALTHCHECK_SRC" /usr/local/sbin/matrix-stack-healthcheck
  chmod +x /usr/local/sbin/matrix-stack-healthcheck
  mkdir -p /var/lib/matrix-healthcheck
  # Monit: run with --check-only so we only alert; timer does the actual restarts
  if grep -q "check program matrix-stack-health" "$MONITRC" 2>/dev/null; then
    true
  else
    cat >> "$MONITRC" << 'MONITHEALTH'

check program matrix-stack-health with path "/usr/local/sbin/matrix-stack-healthcheck --check-only"
  if status != 0 then alert
MONITHEALTH
  fi
  monit -t 2>/dev/null || true
  # Timer: every 5 min, run with restarts (no --check-only)
  cat > /etc/systemd/system/matrix-stack-healthcheck.service << 'EOF'
[Unit]
Description=Matrix stack healthcheck and auto-restart

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/matrix-stack-healthcheck
EOF
  cat > /etc/systemd/system/matrix-stack-healthcheck.timer << 'EOF'
[Unit]
Description=Run Matrix stack healthcheck every 5 minutes

[Timer]
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now matrix-stack-healthcheck.timer 2>/dev/null || true
  echo "  Healthcheck: /usr/local/sbin/matrix-stack-healthcheck (timer every 5 min, Monit check with --check-only)."
else
  echo "  Healthcheck script not found (put matrix-stack-healthcheck.sh in repo or same dir to install)."
fi

# --- Daily digest: systemd timer ---
cat > /usr/local/sbin/vps-digest << 'DIGEST_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
TO="${VPS_DIGEST_TO:-}"
[ -z "$TO" ] && exit 0
HOST="$(hostname -f 2>/dev/null || hostname)"
SUBJECT="Daily digest: ${HOST}"
{
  echo "Host: ${HOST}"
  echo
  echo "== Uptime / load =="
  uptime
  echo
  echo "== Memory =="
  free -h
  echo
  echo "== Disk =="
  df -hT /
  echo
  echo "== Failed systemd units =="
  systemctl --failed --no-pager 2>/dev/null || true
  echo
  echo "== Journal warnings since yesterday =="
  journalctl --since "yesterday" -p warning --no-pager 2>/dev/null || true
  echo
  echo "== Fail2ban summary =="
  fail2ban-client status 2>/dev/null || true
} | /usr/bin/mail -s "${SUBJECT}" "${TO}"
DIGEST_SCRIPT
chmod +x /usr/local/sbin/vps-digest

mkdir -p /etc/systemd/system
# Email is set via drop-in so vps-digest script knows where to send
mkdir -p /etc/systemd/system/vps-digest.service.d
cat > /etc/systemd/system/vps-digest.service << 'EOF'
[Unit]
Description=Send daily VPS digest email

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vps-digest
EOF
printf '%s\n' "[Service]" "Environment=VPS_DIGEST_TO=${ALERT_EMAIL}" > /etc/systemd/system/vps-digest.service.d/email.conf
cat > /etc/systemd/system/vps-digest.timer << 'EOF'
[Unit]
Description=Run daily VPS digest

[Timer]
OnCalendar=*-*-* 08:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now vps-digest.timer 2>/dev/null || true

# --- Test mail (direct; optional root test) ---
echo ""
echo "Sending test email to ${ALERT_EMAIL}..."
echo "Email alerts test from $(hostname -f 2>/dev/null || hostname). msmtp + Monit + daily digest are configured." | mail -s "VPS email alerts test" "$ALERT_EMAIL" 2>/dev/null || true
if [ "$ROUTE_ROOT_MAIL" = "Y" ]; then
  echo "Sending test mail to root (should arrive at ${ALERT_EMAIL})..."
  echo "Root mail test from $(hostname -f 2>/dev/null || hostname). All root mail is forwarded via msmtp." | mail -s "Root mail test" root 2>/dev/null || true
  echo "  Check your inbox for both messages. If no mail, check /var/log/msmtp.log and Gmail App Password."
  echo ""
  echo "Done. Fail2ban will email on bans; Monit will alert; healthcheck every 5 min; daily digest at 08:00; root mail -> ${ALERT_EMAIL}."
else
  echo "  Check your inbox. If no mail, check /var/log/msmtp.log and Gmail App Password."
  echo ""
  echo "Done. Fail2ban will email on bans; Monit will alert; healthcheck every 5 min; daily digest at 08:00."
fi
