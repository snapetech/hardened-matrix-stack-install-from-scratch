#!/usr/bin/env bash
# Run a single script on a remote host with sudo, piping the sudo password from the keyring.
# Uses exactly one newline after the password (printf '%s\n') so sudo -S gets it correctly.
#
# Usage:
#   ./run-remote-sudo.sh <user@host> [script.sh] [script args...]
#   cat script.sh | ./run-remote-sudo.sh <user@host> [script args...]
#
# Keyring: secret-tool lookup service "sudo-remote" user "<user@host>"
#
# IMPORTANT: Run once. If it fails, do NOT retry repeatedly (risk of fail2ban). Fix the cause, then try again.
set -e
REMOTE="${1:?Usage: run-remote-sudo.sh user@host [script.sh]}"
shift || true

PASS=$(secret-tool lookup service sudo-remote user "$REMOTE" 2>/dev/null) || {
  echo "run-remote-sudo.sh: failed to get password from keyring (service=sudo-remote, user=$REMOTE). Stopping." >&2
  exit 1
}

if [[ -n "${1:-}" ]] && [[ -f "${1:-}" ]]; then
  SCRIPT=$(cat "$1")
  shift
fi
if [[ -z "${SCRIPT:-}" ]]; then
  SCRIPT=$(cat)
fi

# One newline after password (sudo -S reads until newline). Then script. Any remaining args are passed to the script (use ROTATE_EXECUTE=1 for rotate-secrets when piping to avoid --execute through ssh).
( printf '%s\n' "$PASS"; printf '%s' "$SCRIPT" ) | ssh "$REMOTE" 'set -e; sudo -S -p "" bash -s "$@"' "" "$@"
exit $?
