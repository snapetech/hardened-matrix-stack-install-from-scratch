#!/usr/bin/env bash
# Single entrypoint for load test: venv, install deps, run run_load_test.py.
set -e
cd "$(dirname "$0")"
VENV="${VENV:-.venv}"
if [[ ! -d "$VENV" ]]; then
  python3 -m venv "$VENV"
fi
# shellcheck source=/dev/null
source "$VENV/bin/activate"
if [[ -f .env ]]; then set -a; source .env; set +a; fi
pip install -q -r requirements.txt
exec python3 scripts/run_load_test.py "$@"
