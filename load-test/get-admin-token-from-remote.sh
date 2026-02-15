#!/usr/bin/env bash
# Fetch admin token from remote (Mjolnir token from timeways.net) and write to .env.
# Usage: ./get-admin-token-from-remote.sh [user@host]
# Then run: ./run.sh ...
# Note: Admin API is only allowed from localhost on the server. So either:
#   - Run the load test ON the server (cd load-test && ./run.sh ...) with config server_url: http://127.0.0.1:8008 and token in config, or
#   - Install on server: sudo apt install -y python3-pip python3.13-venv
set -e
REMOTE="${1:-lukano@timeways.net}"
TOKEN=$(ssh -o BatchMode=yes "$REMOTE" "grep accessToken /home/lukano/mjolnir-production.yaml 2>/dev/null | sed 's/.*: *\"\\(.*\\)\".*/\1/'" 2>/dev/null)
if [[ -z "$TOKEN" ]]; then
  echo "Failed to get token from $REMOTE" >&2
  exit 1
fi
cd "$(dirname "$0")"
if [[ -f .env ]]; then
  grep -v "^ADMIN_ACCESS_TOKEN=" .env > .env.tmp || true
  mv .env.tmp .env
fi
echo "ADMIN_ACCESS_TOKEN=$TOKEN" >> .env
echo "Wrote ADMIN_ACCESS_TOKEN to .env (token length ${#TOKEN})"
