#!/usr/bin/env bash
# Matrix stack healthcheck: detect crashed services/containers, restart them, optionally reboot.
# Exit 0 = all healthy (or recovered), 1 = something still down after restart attempts.
# Usage: sudo ./matrix-stack-healthcheck.sh [--check-only] [--allow-reboot] [--clear-fail2ban]
#   --check-only   only report status, no restarts
#   --allow-reboot if critical (nginx/synapse) still down after 3 runs, create reboot marker;
#                  next run with --allow-reboot performs reboot in 60s. Or touch $STATE_DIR/request-reboot to request reboot.
#   --clear-fail2ban  unban all currently banned IPs in all fail2ban jails, then exit (no other checks).
# Element Call (docker compose in /opt/element-call) is checked if present; create $STATE_DIR/skip-element-call to skip.
# Used by: Monit (--check-only) and systemd timer (periodic run with restarts).
set -euo pipefail

CHECK_ONLY=false
ALLOW_REBOOT=false
CLEAR_FAIL2BAN=false
for arg in "$@"; do
  [ "$arg" = "--check-only" ] && CHECK_ONLY=true
  [ "$arg" = "--allow-reboot" ] && ALLOW_REBOOT=true
  [ "$arg" = "--clear-fail2ban" ] && CLEAR_FAIL2BAN=true
done

LOG() { echo "$(date -Iseconds) $*" | tee -a "${LOG_FILE:-/var/log/matrix-healthcheck.log}" 2>/dev/null || true; }
STATE_DIR="${STATE_DIR:-/var/lib/matrix-healthcheck}"
REBOOT_MARKER="$STATE_DIR/request-reboot"
FAILURE_COUNT="$STATE_DIR/failure-count"

mkdir -p "$STATE_DIR"
: >> "${LOG_FILE:-/var/log/matrix-healthcheck.log}"

# --- Optional: clear all fail2ban blocks (unban every IP in every jail), then exit ---
if [ "$CLEAR_FAIL2BAN" = true ]; then
  if ! command -v fail2ban-client &>/dev/null; then
    LOG "clear-fail2ban: fail2ban-client not found"
    exit 0
  fi
  # Jail list line is e.g. "Jail list:	sshd, matrix-synapse-auth"
  jails=$(fail2ban-client status 2>/dev/null | sed -n 's/^.*Jail list:[[:space:]]*//p' | tr ',' ' ')
  for jail in $jails; do
    jail=$(echo "$jail" | tr -d '[:space:]')
    [ -z "$jail" ] && continue
    # Banned IP list is e.g. "Banned IP list:	1.2.3.4 5.6.7.8"
    ips=$(fail2ban-client status "$jail" 2>/dev/null | sed -n 's/^.*Banned IP list:[[:space:]]*//p' | tr '\t' ' ')
    for ip in $ips; do
      [ -z "$ip" ] && continue
      if fail2ban-client set "$jail" unbanip "$ip" 2>/dev/null; then
        LOG "clear-fail2ban: unbanned $ip from $jail"
      fi
    done
  done
  LOG "clear-fail2ban: done"
  exit 0
fi

FAILED_ANY=false

# --- Systemd services (only restart if unit exists and is enabled or was previously active) ---
SYSTEMD_SERVICES=(nginx matrix-synapse postgresql fail2ban monit coturn)
for unit in "${SYSTEMD_SERVICES[@]}"; do
  if ! systemctl cat "$unit.service" &>/dev/null; then
    continue
  fi
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    continue
  fi
  if [ "$CHECK_ONLY" = true ]; then
    LOG "systemd $unit: not active (no restart: --check-only)"
    FAILED_ANY=true
    continue
  fi
  LOG "systemd $unit: not active, restarting..."
  if systemctl restart "$unit" 2>/dev/null; then
    LOG "systemd $unit: restarted OK"
  else
    LOG "systemd $unit: restart failed"
    FAILED_ANY=true
  fi
done

# --- Docker containers (only if container exists) ---
if command -v docker &>/dev/null; then
  DOCKER_CONTAINERS=(draupnir mjolnir)
  for name in "${DOCKER_CONTAINERS[@]}"; do
    if ! docker inspect "$name" &>/dev/null 2>&1; then
      continue
    fi
    running=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo "false")
    if [ "$running" = "true" ]; then
      continue
    fi
    if [ "$CHECK_ONLY" = true ]; then
      LOG "docker $name: not running (no restart: --check-only)"
      FAILED_ANY=true
      continue
    fi
    LOG "docker $name: not running, starting..."
    if docker start "$name" 2>/dev/null; then
      LOG "docker $name: started OK"
    else
      LOG "docker $name: start failed, trying restart..."
      docker restart "$name" 2>/dev/null && LOG "docker $name: restarted OK" || { LOG "docker $name: restart failed"; FAILED_ANY=true; }
    fi
  done
  # Element Call: docker compose in /opt/element-call (skip if opt-out file present)
  if [ -d /opt/element-call ] && [ -f /opt/element-call/docker-compose.yml ] && [ ! -f "$STATE_DIR/skip-element-call" ]; then
    (
      cd /opt/element-call
      up=$(docker compose ps -q 2>/dev/null || docker-compose ps -q 2>/dev/null)
      if [ -z "$up" ] || docker compose ps 2>/dev/null | grep -qE "Exit|exited|Restarting"; then
        if [ "$CHECK_ONLY" = true ]; then
          LOG "element-call compose: not all running (no restart: --check-only)"
          exit 1
        fi
        LOG "element-call: bringing up..."
        (docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null) && LOG "element-call: up OK" || exit 1
      fi
    ) || FAILED_ANY=true
  fi
fi

# --- Critical: nginx + matrix-synapse must be up ---
CRITICAL_FAILED=false
for unit in nginx matrix-synapse; do
  if systemctl cat "$unit.service" &>/dev/null && ! systemctl is-active --quiet "$unit" 2>/dev/null; then
    CRITICAL_FAILED=true
    break
  fi
done

# --- Reboot: only if allowed and critical still down (or explicit marker) ---
if [ "$ALLOW_REBOOT" = true ]; then
  if [ -f "$REBOOT_MARKER" ]; then
    LOG "Reboot requested (marker file present). Rebooting in 60s..."
    rm -f "$REBOOT_MARKER"
    sleep 60
    systemctl reboot
    exit 0
  fi
  if [ "$CRITICAL_FAILED" = true ]; then
    count=0
    [ -f "$FAILURE_COUNT" ] && count=$(cat "$FAILURE_COUNT")
    count=$((count + 1))
    echo "$count" > "$FAILURE_COUNT"
    if [ "$count" -ge 3 ]; then
      LOG "Critical service still down after 3 runs. Requesting reboot (create $REBOOT_MARKER to confirm, or run with --allow-reboot again)."
      touch "$REBOOT_MARKER"
      echo 0 > "$FAILURE_COUNT"
    fi
  else
    echo 0 > "$FAILURE_COUNT"
  fi
fi

[ "$FAILED_ANY" = true ] && exit 1
[ "$CRITICAL_FAILED" = true ] && exit 1
exit 0
