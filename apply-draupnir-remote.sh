#!/bin/bash
# On remote: create /opt/draupnir, write config (from env or existing file), start Draupnir container.
# Run on server: sudo bash apply-draupnir-remote.sh
#   Or: (echo 'BASE=https://matrix.example.com'; echo 'SERVER_NAME=example.com'; echo 'DRAUPNIR_ACCESS_TOKEN=...'; echo 'DRAUPNIR_MANAGEMENT_ROOM=!xxx:example.com'; cat apply-draupnir-remote.sh) | ./run-remote-sudo.sh user@host
# If DRAUPNIR_ACCESS_TOKEN and DRAUPNIR_MANAGEMENT_ROOM are set, config is generated; otherwise /opt/draupnir/config/production.yaml must already exist (e.g. from setup-draupnir.sh output).
set -e
BASE="${BASE:-https://matrix.example.com}"
SERVER_NAME="${SERVER_NAME:-example.com}"

echo "[1] Ensure Docker..."
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
  systemctl start docker
fi

echo "[2] Create /opt/draupnir..."
mkdir -p /opt/draupnir/config /opt/draupnir/data

if [ -n "$DRAUPNIR_ACCESS_TOKEN" ] && [ -n "$DRAUPNIR_MANAGEMENT_ROOM" ]; then
  echo "[3] Writing production.yaml from env..."
  cat > /opt/draupnir/config/production.yaml << EOF
homeserverUrl: "$BASE"
rawHomeserverUrl: "$BASE"
accessToken: "$DRAUPNIR_ACCESS_TOKEN"
managementRoom: "$DRAUPNIR_MANAGEMENT_ROOM"
dataPath: "/data/storage"
autojoinOnlyIfManager: true
logLevel: "INFO"
verifyPermissionsOnStartup: true
noop: false
EOF
  chmod 600 /opt/draupnir/config/production.yaml
else
  echo "[3] Using existing /opt/draupnir/config/production.yaml (set DRAUPNIR_ACCESS_TOKEN and DRAUPNIR_MANAGEMENT_ROOM to generate)."
  if [ ! -f /opt/draupnir/config/production.yaml ]; then
    echo "  No config found. Run setup-draupnir.sh locally, then copy production.yaml to server /opt/draupnir/config/ and re-run this script." >&2
    exit 1
  fi
fi

echo "[4] Pull and start Draupnir container..."
docker pull gnuxie/draupnir:latest
docker stop draupnir 2>/dev/null || true
docker rm draupnir 2>/dev/null || true
docker run -d --name draupnir --restart unless-stopped \
  -v /opt/draupnir/config/production.yaml:/data/config/production.yaml:ro \
  -v /opt/draupnir/data:/data/storage \
  gnuxie/draupnir:latest bot --draupnir-config /data/config/production.yaml

echo "Done. Draupnir container 'draupnir' is running. Check: docker logs -f draupnir"
