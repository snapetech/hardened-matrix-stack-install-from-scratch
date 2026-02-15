# Fail2ban configs

- **sshd** (sshd-lenient.conf) — SSH: `maxretry = 10`, `findtime = 10m`. **Bantime = -1 (permanent):** SSH bans stay until you clear them manually (`fail2ban-client set sshd unbanip <ip>` or `fail2ban-whitelist-ssh-client.sh`). Reduces risk of locking yourself out by requiring 10 failures in 10m before banning.
- **matrix-synapse-auth** — Bans on repeated **failed** Matrix login/register (401, 403, 429 in nginx access log). **Successful** requests (200) do **not** count. **Bantime = 1h:** bans auto-expire after 1 hour so normal usage (Synapse, Element, LiveKit, etc.) can cycle out. Other app-level jails you add can use the same short bantime.

Install: copy `filter.d/*` and `jail.d/*` to `/etc/fail2ban/` (e.g. via setup-from-scratch.sh). Then `sudo fail2ban-client reload`.
