# Grafana dashboards and provisioning (Matrix)

## Dashboards

- **matrix-overview.json** — Single-server overview: Synapse event latency, events/s, CPU/memory, reactor tick; node memory/disk/CPU; targets up. No variables; works with one Prometheus datasource (UID `prometheus`).
- **Synapse (official):** Import dashboard **13894** from [Grafana.com](https://grafana.com/grafana/dashboards/13894) (Synapse by toox). Set variable `server_name` to your server name and ensure Prometheus scrapes Synapse with `job="synapse"`.

## Provisioning

1. **Copy dashboards** to a path your Grafana can read, e.g.:
   ```bash
   sudo mkdir -p /etc/grafana/provisioning/dashboards/matrix
   sudo cp grafana/dashboards/*.json /etc/grafana/provisioning/dashboards/matrix/
   ```

2. **Configure dashboard provider** — Copy or symlink `provisioning/dashboards/dashboards.yml` into Grafana’s provisioning directory and set `path` to the same directory (e.g. `/etc/grafana/provisioning/dashboards/matrix`). Example for a system install:
   ```yaml
   # /etc/grafana/provisioning/dashboards/dashboards.yml
   apiVersion: 1
   providers:
     - name: 'matrix'
       folder: 'Matrix'
       folderUid: 'matrix'
       type: file
       options:
         path: /etc/grafana/provisioning/dashboards/matrix
   ```

3. **Datasource** — Add a Prometheus data source in Grafana with URL `http://127.0.0.1:9090` (or the URL Grafana uses to reach Prometheus). Set its UID to `prometheus` so the overview dashboard finds it, or edit the dashboard JSON to use your datasource UID.

4. **Restart Grafana** so it reloads provisioning.

## If Grafana is behind the metrics auth proxy

When Grafana is served at e.g. `https://matrix.example.com/metrics/grafana/`, configure the Prometheus datasource to use the same origin or an internal URL (e.g. `http://127.0.0.1:9090`) so Grafana can scrape Prometheus without going through the public URL.
