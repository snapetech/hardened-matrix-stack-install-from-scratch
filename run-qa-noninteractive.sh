#!/bin/bash
# Run the Matrix stack installer in non-interactive mode (QA / automation).
# Use on a Debian/Ubuntu host or inside a Debian VM. For self-signed cert (no DNS), set USE_SELF_SIGNED_CERT=1.
#
# Example (self-signed, minimal options):
#   sudo -E ./run-qa-noninteractive.sh
#
# Env vars (all optional when NON_INTERACTIVE=1):
#   MATRIX_DOMAIN, SERVER_NAME, ROOT_DOMAIN, LE_EMAIL
#   FEDERATION, INSTALL_COTURN, INSTALL_MONITORING, INSTALL_ELEMENT_CALL, INSTALL_FAIL2BAN,
#   INSTALL_BACKUP_CRON, INSTALL_MJOLNIR, INSTALL_MAUBOT, INSTALL_DISCORD, INSTALL_METRICS_AUTH
#   USE_SELF_SIGNED_CERT=1  -- skip Let's Encrypt, use self-signed (for QA without DNS)
#   ADMIN_USER, ADMIN_PASSWORD -- first admin (if ADMIN_PASSWORD set, user is created)
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_DIR="$SCRIPT_DIR"
export NON_INTERACTIVE=1
# Defaults for QA
export MATRIX_DOMAIN="${MATRIX_DOMAIN:-matrix.qa.local}"
export SERVER_NAME="${SERVER_NAME:-qa.local}"
export ROOT_DOMAIN="${ROOT_DOMAIN:-$SERVER_NAME}"
export LE_EMAIL="${LE_EMAIL:-admin@$SERVER_NAME}"
export USE_SELF_SIGNED_CERT="${USE_SELF_SIGNED_CERT:-1}"
export ADMIN_USER="${ADMIN_USER:-admin}"
# Optional: set ADMIN_PASSWORD to create admin user non-interactively
export ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
exec "$SCRIPT_DIR/setup-from-scratch.sh"
