#!/usr/bin/env bash
# Claim this host's Netdata agent to Netdata Cloud (run on server with sudo).
# Usage: ./run-remote-sudo.sh user@host netdata-claim-remote.sh
# Or on server: sudo bash netdata-claim-remote.sh
# Set token: (echo 'NETDATA_CLAIM_TOKEN=your-token-here'; cat netdata-claim-remote.sh) | ./run-remote-sudo.sh user@host
set -e
TOKEN="${NETDATA_CLAIM_TOKEN:?Set NETDATA_CLAIM_TOKEN (your claim token from Netdata Cloud)}"
echo "=== Outbound test (5s timeout) ==="
if curl -sS -o /dev/null -w "HTTP %{http_code}\n" --connect-timeout 5 --max-time 5 https://app.netdata.cloud/ 2>/dev/null; then
  echo "OK - agent can reach Netdata Cloud."
else
  echo "FAIL or timeout - outbound HTTPS to app.netdata.cloud may be blocked. Open firewall or check proxy."
fi
echo ""
echo "=== Writing /etc/netdata/claim.conf ==="
mkdir -p /etc/netdata
cat > /etc/netdata/claim.conf << EOF
[global]
url = https://app.netdata.cloud
token = $TOKEN
EOF
chmod 600 /etc/netdata/claim.conf
echo "Done."
echo ""
echo "=== Reload claiming + restart Netdata ==="
netdatacli reload-claiming-state 2>/dev/null || true
systemctl restart netdata
echo "Waiting 10s for claim..."
sleep 10
echo ""
echo "=== Cloud status (api/v3/info) ==="
curl -sS --max-time 3 http://127.0.0.1:19999/api/v3/info 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    c = d.get('cloud', {})
    print('Claimed:', c.get('claimed', '?'))
    print('Claimed ID:', c.get('claimed_id', '?'))
    print('Online:', c.get('aclk', {}).get('online', '?'))
    if c.get('aclk', {}).get('error'):
        print('ACLK error:', c['aclk']['error'])
except Exception as e:
    print(e)
" 2>/dev/null || echo "Could not get info"
echo ""
echo "=== Last CLAIM lines in daemon.log ==="
grep -i claim /var/log/netdata/daemon.log 2>/dev/null | tail -10 || echo "(none)"
echo ""
echo "If still stuck: check firewall allows outbound HTTPS to app.netdata.cloud; or set proxy in claim.conf (see Netdata docs)."
