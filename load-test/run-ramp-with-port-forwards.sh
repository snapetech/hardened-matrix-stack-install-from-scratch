#!/usr/bin/env bash
# Start port-forwards (nginx 30048, livekit 30049, lk-jwt 30050) then run ramp_harness.py.
# Requires KUBECONFIG and kubectl. Run from repo root or load-test/.
# Usage: ./load-test/run-ramp-with-port-forwards.sh [ramp_harness.py args...]
# Example: ./load-test/run-ramp-with-port-forwards.sh --config config-ramp-qa.yaml --min 2 --max 2 --tier1-duration 60 --skip-tier2
# Single-pass (ramp up 5->10 in one run): add --single-pass --min 5 --max 10 --tier1-duration 360 --skip-tier2
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
NS="${MATRIX_QA_NAMESPACE:-matrix-qa}"

echo "Starting port-forwards (nginx 30048, livekit 30049, lk-jwt 30050)..."
kubectl port-forward -n "$NS" svc/nginx 30048:80 &
PF1=$!
kubectl port-forward -n "$NS" svc/livekit 30049:7880 &
PF2=$!
kubectl port-forward -n "$NS" svc/lk-jwt 30050:6080 &
PF3=$!
trap "kill $PF1 $PF2 $PF3 2>/dev/null" EXIT
sleep 5

export MATRIX_BASE_URL="http://localhost:30048"
export LIVEKIT_WS_URL="ws://localhost:30049"
export LIVEKIT_JWT_URL="http://localhost:30050"
if [ -f "$SCRIPT_DIR/test_room_id.txt" ]; then
  export TEST_ROOM_ID="$(cat "$SCRIPT_DIR/test_room_id.txt")"
fi

cd "$SCRIPT_DIR"
VENV_PY="$SCRIPT_DIR/.venv/bin/python3"
[ -x "$VENV_PY" ] || { echo "Create venv first: python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"; exit 1; }
exec "$VENV_PY" scripts/ramp_harness.py "$@"
