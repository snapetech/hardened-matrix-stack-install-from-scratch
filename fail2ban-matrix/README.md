# Fail2ban configs

- **matrix-synapse-auth** — Bans on repeated **failed** Matrix login/register (401, 403, 429 in nginx access log). **Successful** requests (200) do **not** count. So load tests or many concurrent successful logins from one IP will **not** trigger this jail.
- **sshd-lenient** — SSH/sudo: `maxretry = 10`, `findtime = 10m`, `bantime = 10m`. Reduces risk of banning your own IP when running a few remote-sudo attempts or multiple SSH sessions from the same machine.

Install: copy `filter.d/*` and `jail.d/*` to `/etc/fail2ban/` (e.g. via setup-from-scratch.sh). Then `sudo fail2ban-client reload`.
