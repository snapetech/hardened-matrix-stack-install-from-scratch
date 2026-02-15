#!/usr/bin/env bash
# Run only the quick/smoke tests (no login, no rooms). Use after deploy-only.sh to iterate
# on failures (e.g. metrics, well-known) without running the full suite.
#   ./k8s-qa/run-quick-tests.sh
#   MATRIX_BASE_URL=http://localhost:30048 ./k8s-qa/run-quick-tests.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_URL="${MATRIX_BASE_URL:-http://localhost:30048}"
BASE_URL="${BASE_URL%/}"

# Quick tests only (no login/rooms). Respect FEDERATION_ENABLED for federation vs block checks.
if [ "${FEDERATION_ENABLED:-0}" = "1" ]; then
  export MATRIX_QA_TESTS="versions,federation_allowed,wellknown_server,wellknown_client,metrics"
else
  export MATRIX_QA_TESTS="versions,federation_blocked,wellknown_client,metrics"
fi
"$SCRIPT_DIR/run-matrix-qa-tests.sh" "$BASE_URL"
