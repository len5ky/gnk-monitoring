# Remote Monitoring Agent

## Prerequisites
- Docker + Docker Compose installed
- Outbound access to monitor host on ports 8446 (logs) and 8448 (metrics)

## Files in this folder
- `docker-compose.yml` — runs Promtail, Grafana Agent, exporters, connectivity checker
- `deploy-promtail.sh` — automated deployment script (recommended)
- `connectivity/` — inventory and profile templates for connectivity checks

## Scripted Deployment (Recommended)

This method is ideal when this `remote` directory is on shared storage, avoiding the need to copy files to each node. The script handles the creation of local data directories and configuration.

1.  Ensure this `remote` directory is accessible on the target node (e.g., via an NFS mount).
2.  Execute the deployment script as root, providing a unique instance ID for the node:

    ```bash
    # Navigate to the shared directory where the script is located
    cd /path/to/shared/monitoring/remote

    # Run the script with sudo
    sudo ./deploy-promtail.sh <unique-id-for-this-node>
    ```

    For example:
    ```bash
    sudo ./deploy-promtail.sh my-web-server-01
    ```
3.  The script will create all necessary local files in `/opt/promtail-agent` and start Promtail, Grafana Agent, node-exporter, nvidia-gpu-exporter (if GPU detected), and connectivity checker.

## Manual Setup

If you prefer to set up Promtail manually on each node, follow these steps.

1.  **Copy Files**: Copy this entire folder to the remote node, for example to `/opt/monitoring-promtail`.
2.  **Configure Promtail**: Edit `promtail-config.yml` and replace `REPLACE_WITH_MONITOR_HOST_OR_IP` with the IP address or hostname of your central Loki instance.
3.  **Create Environment File**: Create a `.env` file with credentials:
    ```bash
    cat > .env <<'EOF'
    INSTANCE_ID=<unique-id-for-this-node>
    INSTANCE_IP=<this-node-ip>
    GF_SERVER_ROOT_IP=<monitor-host-ip>
    NETWORKNODE_IP=<monitor-host-ip>
    LOKI_INGEST_USER=loki
    LOKI_INGEST_PASSWORD=<same-as-monitor-host>
    PROMETHEUS_USER=prometheus
    PROMETHEUS_PASSWORD=<same-as-monitor-host>
    CONNECTIVITY_POLL_INTERVAL=10s
    CONNECTIVITY_REQUEST_TIMEOUT=5s
    EOF
    ```
4.  **Create Data Directory**: Create a local directory for Promtail to store its position files:
    ```bash
    mkdir -p data/promtail
    ```
5.  **Start Services**:
    ```bash
    # From the /opt/monitoring-promtail directory
    docker compose up -d
    ```
6.  **Verify**: Check that the container is running and view its logs:
    ```bash
    docker compose ps
    docker compose logs -f
    ```

## Configuration Details

### Logs (Promtail)
- Discovers Docker containers via `/var/run/docker.sock` and tails logs.
- Labels: `instance_id`, `instance_ip`, `container`, `compose_project`, `compose_service`.
- Pushes to Loki on port 8446 (HTTPS + basic auth).

### Metrics (Grafana Agent + Exporters)
- **Grafana Agent**: Scrapes local exporters, pushes to Prometheus port 8448 (HTTPS + auth).
- **node-exporter**: Binds to 127.0.0.1:9100 (localhost only), collects system metrics.
- **nvidia-gpu-exporter**: Binds to 127.0.0.1:9835 (localhost only), collects GPU metrics.
- **Security**: Exporters are NOT exposed to the network, only accessible by Grafana Agent.

### Connectivity Checker
- Emits JSON logs tagged with `kind` (`ping`/`http`), `status`, `latency_s`, and `instance_id`.
- Uses templates with `${NETWORKNODE_IP}` substitution.

### Dashboards
- "System Metrics (Node Exporter)": CPU, RAM, disk, network, GPU metrics.
- "Connectivity Monitor": Connectivity test results.
- Filter by `instance_id` to view specific nodes.


easy to run:
sudo /mnt/filesystem-o0/monitoring/remote/deploy-promtail.sh <grose-