#!/usr/bin/env bash
# Run load test on the server when venv/pip from apt isn't available.
# Bootstraps pip via get-pip.py (no sudo), installs deps to --user, runs test.
# Usage: ./run-on-server.sh [run.sh args...]
set -e
cd "$(dirname "$0")"
if [[ -f .env ]]; then set -a; source .env; set +a; fi

if ! python3 -m pip --version &>/dev/null; then
  echo "No pip found; bootstrapping with get-pip.py (--user)..."
  GETPIP="${GETPIP:-/tmp/get-pip.py}"
  if [[ ! -f "$GETPIP" ]]; then
    curl -sSfL https://bootstrap.pypa.io/get-pip.py -o "$GETPIP" || { echo "Failed to download get-pip.py"; exit 1; }
  fi
  python3 "$GETPIP" --user
  export PATH="$HOME/.local/bin:$PATH"
fi
python3 -m pip install -q --user -r requirements.txt
exec python3 scripts/run_load_test.py "$@"
