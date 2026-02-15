#!/bin/bash
# Validate that this server is not federating (spam-free federation surface).
# Run on the Synapse host (sudo optional; some checks need read access to config).
# Exit 0 = all checks pass (no federation surface). Exit 1 = one or more checks failed.
#
# Checks:
#  1) Synapse: federation_domain_whitelist is [] (or 44-no-federation.yaml present).
#  2) Synapse: listener has only [client], no federation resource.
#  3) No process listening on federation port 8448.
#  4) Optional: nginx blocks /_matrix/federation and does not serve /.well-known/matrix/server.
set -e

FAIL=0

# 1) Federation whitelist empty
echo -n "[1] federation_domain_whitelist: [] ... "
if [ -f /etc/matrix-synapse/conf.d/44-no-federation.yaml ]; then
  if grep -q "federation_domain_whitelist: \[\]" /etc/matrix-synapse/conf.d/44-no-federation.yaml 2>/dev/null; then
    echo "OK (44-no-federation.yaml with whitelist: [])"
  else
    echo "FAIL (44-no-federation.yaml present but whitelist not [])"
    FAIL=1
  fi
else
  # Check main config or any conf.d
  WHITELIST_OK=""
  for f in /etc/matrix-synapse/homeserver.yaml /etc/matrix-synapse/conf.d/*.yaml; do
    [ -f "$f" ] || continue
    if grep "federation_domain_whitelist" "$f" 2>/dev/null | grep -qE "\[\]|\[\s*\]"; then
      WHITELIST_OK=1
      break
    fi
  done
  if [ -n "$WHITELIST_OK" ]; then
    echo "OK (whitelist [] in config)"
  else
    echo "FAIL (no federation_domain_whitelist: [] and no 44-no-federation.yaml)"
    FAIL=1
  fi
fi

# 2) Listener has only client, no federation
echo -n "[2] listener resources: [client] only ... "
HAS_FED=""
for f in /etc/matrix-synapse/homeserver.yaml /etc/matrix-synapse/conf.d/listener.yaml /etc/matrix-synapse/conf.d/*.yaml; do
  [ -f "$f" ] || continue
  if grep -l "federation" "$f" 2>/dev/null | grep -q .; then
    if grep -E "names:.*federation|resources:.*federation" "$f" 2>/dev/null | grep -v "names: \[client\]" | grep -q .; then
      HAS_FED=1
      break
    fi
  fi
done
if [ -z "$HAS_FED" ]; then
  echo "OK (no federation resource in listeners)"
else
  echo "FAIL (listener includes federation resource)"
  FAIL=1
fi

# 3) Nothing listening on 8448
echo -n "[3] port 8448 not in use for federation ... "
if command -v ss &>/dev/null; then
  if ss -lntp 2>/dev/null | grep -q ':8448'; then
    echo "FAIL (port 8448 is listening)"
    FAIL=1
  else
    echo "OK (8448 not listening)"
  fi
elif command -v netstat &>/dev/null; then
  if netstat -lntp 2>/dev/null | grep -q ':8448'; then
    echo "FAIL (port 8448 is listening)"
    FAIL=1
  else
    echo "OK (8448 not listening)"
  fi
else
  echo "SKIP (ss/netstat not found)"
fi

# 4) Nginx: block federation path and well-known server (optional)
echo -n "[4] nginx blocks /_matrix/federation (when no-federation) ... "
MATRIX_VHOST=""
for v in /etc/nginx/sites-enabled/matrix /etc/nginx/sites-available/matrix /etc/nginx/sites-enabled/* /etc/nginx/sites-available/*; do
  [ -f "$v" ] && grep -q "_matrix" "$v" 2>/dev/null && MATRIX_VHOST="$v" && break
done
BLOCK_OK=""
if [ -n "$MATRIX_VHOST" ]; then
  if grep -q "_matrix/federation" "$MATRIX_VHOST" 2>/dev/null; then
    grep -A1 "_matrix/federation" "$MATRIX_VHOST" | grep -qE "return 403|return 444|deny" && BLOCK_OK=1
  fi
  if [ -z "$BLOCK_OK" ] && grep -q "no-federation.conf" "$MATRIX_VHOST" 2>/dev/null; then
    [ -f /etc/nginx/snippets/no-federation.conf ] && \
      grep -q "_matrix/federation" /etc/nginx/snippets/no-federation.conf 2>/dev/null && \
      grep -q "return 403\|return 444" /etc/nginx/snippets/no-federation.conf 2>/dev/null && \
      BLOCK_OK=1
  fi
  if [ -n "$BLOCK_OK" ]; then
    echo "OK (explicit block present)"
  else
    echo "WARN (no explicit block; relies on Synapse not serving federation)"
  fi
else
  echo "SKIP (no matrix vhost found)"
fi

if [ "$FAIL" -eq 0 ]; then
  echo ""
  echo "All required checks passed. Federation surface is disabled."
  exit 0
else
  echo ""
  echo "One or more checks failed. Fix config and re-run."
  exit 1
fi
