#!/usr/bin/env bash
# Run a remote command inside a named screen so you can attach and monitor.
# Usage:
#   ./run-remote-in-screen.sh <user@host> <session_name> [-w] -- <command>
#   ./run-remote-in-screen.sh <user@host> <session_name> [-w] < script.sh
#
# Attach: ssh <user@host> then screen -r <session_name>
# With -w: wait for the screen to exit, then screen -wipe.
set -e
REMOTE="${1:?Usage: run-remote-in-screen.sh user@host session_name [-w] [-- command]}"
SESSION="${2:?Usage: run-remote-in-screen.sh user@host session_name [-w] [-- command]}"
WAIT=
shift 2
[[ "${1:-}" = "-w" ]] && { WAIT=1; shift; }

REMOTE_SCRIPT="/tmp/run_in_screen_$$.sh"
if [[ "${1:-}" = "--" ]]; then
  shift
  # Write command to temp file, scp, run in screen
  TMP=$(mktemp)
  trap 'rm -f "$TMP"' EXIT
  printf '%s\n' "$*" > "$TMP"
  scp -q "$TMP" "$REMOTE:$REMOTE_SCRIPT"
  ssh "$REMOTE" "chmod +x $REMOTE_SCRIPT; screen -dmS $SESSION bash $REMOTE_SCRIPT"
else
  # Script from stdin
  TMP=$(mktemp)
  trap 'rm -f "$TMP"' EXIT
  cat > "$TMP"
  scp -q "$TMP" "$REMOTE:$REMOTE_SCRIPT"
  ssh "$REMOTE" "chmod +x $REMOTE_SCRIPT; screen -dmS $SESSION bash $REMOTE_SCRIPT"
fi

echo "Started screen '$SESSION' on $REMOTE. Attach with: ssh $REMOTE 'screen -r $SESSION'"

if [[ -n "$WAIT" ]]; then
  echo "Waiting for screen '$SESSION' to exit..."
  while ssh "$REMOTE" "screen -ls" 2>/dev/null | grep -q "$SESSION"; do
    sleep 5
  done
  echo "Screen '$SESSION' finished."
  ssh "$REMOTE" "screen -wipe 2>/dev/null; rm -f $REMOTE_SCRIPT" 2>/dev/null || true
fi
