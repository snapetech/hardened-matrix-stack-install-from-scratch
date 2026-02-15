# Netdata (gated behind Synapse)

The setup script installs Netdata and optionally gates it behind Synapse login via the metrics-auth proxy. When gated, no Netdata login is required—you log in once with your Matrix account at `/metrics-auth/` and then view Netdata at `/metrics/`.

- **netdata-bind-localhost.conf** — Copy to `/etc/netdata/netdata.conf.d/bind-localhost.conf` so the web UI listens only on 127.0.0.1 (nginx reverse-proxies with auth).

If you want to use Netdata Cloud or sign in with a Google account inside Netdata, you can enable that in Netdata’s UI or config after setup; the gate is at nginx (Matrix login), not inside Netdata.
