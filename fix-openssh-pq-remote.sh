#!/bin/bash
# Enable post-quantum key exchange on the SSH server to fix the "store now, decrypt later" warning.
# Run on server: sudo bash fix-openssh-pq-remote.sh
# Or: cat fix-openssh-pq-remote.sh | ./run-remote-sudo.sh user@host
#
# Requires OpenSSH 9.0+ (for sntrup761). Prefer 9.9+ (for mlkem768). Does not remove existing
# algorithms so older clients still work. See https://openssh.com/pq.html
set -e

SSHD_CONFIG="/etc/ssh/sshd_config"
# PQ first (9.0+ and 9.9+), then keep common classic for compatibility
PQ_KEX="sntrup761x25519-sha512@openssh.com,mlkem768x25519-sha256"
FALLBACK_KEX="curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group-exchange-sha256,diffie-hellman-group14-sha256"
NEW_KEX="${PQ_KEX},${FALLBACK_KEX}"

echo "[1] Check OpenSSH server supports PQ KEX..."
if ! ssh -Q kex 2>/dev/null | grep -qE "sntrup761|mlkem768"; then
  echo "  OpenSSH on this host does not support post-quantum KEX (need 9.0+). Upgrade OpenSSH."
  exit 1
fi

echo "[2] Backup and update sshd_config..."
BACKUP="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
cp -a "$SSHD_CONFIG" "$BACKUP"
if grep -qE "^[[:space:]]*KexAlgorithms[[:space:]]" "$SSHD_CONFIG"; then
  sed -i "s/^[[:space:]]*KexAlgorithms[[:space:]]*.*/KexAlgorithms ${NEW_KEX}/" "$SSHD_CONFIG"
  echo "  Replaced existing KexAlgorithms with PQ-first list."
else
  echo "KexAlgorithms ${NEW_KEX}" >> "$SSHD_CONFIG"
  echo "  Appended KexAlgorithms (PQ-first)."
fi

echo "[3] Test sshd config..."
if ! sshd -t 2>/dev/null; then
  echo "  sshd -t failed. Restoring backup."
  cp -a "$BACKUP" "$SSHD_CONFIG"
  exit 1
fi

echo "[4] Reload sshd..."
if systemctl reload ssh 2>/dev/null; then
  :
elif systemctl reload sshd 2>/dev/null; then
  :
else
  echo "  Reload failed; try: sudo systemctl restart ssh"
  exit 1
fi

echo "Done. New connections should use post-quantum KEX. Verify with: ssh -v user@host 2>&1 | grep -i kex"
