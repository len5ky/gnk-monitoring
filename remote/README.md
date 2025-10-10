# Remote Promtail (push logs to central Loki)

## Prerequisites
- Docker + Docker Compose installed
- Access from remote node to your monitor host IP/hostname on port 8446 (HTTPS)

## Files in this folder
- `docker-compose.yml` — runs promtail container
- `promtail-config.yml` — promtail configuration; edit to set your monitor host/IP

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
3.  The script will create all necessary local files in `/opt/promtail-agent` and start the Promtail container.

## Manual Setup

If you prefer to set up Promtail manually on each node, follow these steps.

1.  **Copy Files**: Copy this entire folder to the remote node, for example to `/opt/monitoring-promtail`.
2.  **Configure Promtail**: Edit `promtail-config.yml` and replace `REPLACE_WITH_MONITOR_HOST_OR_IP` with the IP address or hostname of your central Loki instance.
3.  **Create Environment File**: Create a `.env` file with credentials and instance labels:
    ```bash
    cat > .env <<'EOF'
    LOKI_INGEST_USER=promtail
    LOKI_INGEST_PASSWORD=<ask-ops-for-password>
    INSTANCE_ID=<unique-id-for-this-node>
    INSTANCE_IP=$(hostname -I | awk '{print $1}')
    EOF
    ```
4.  **Create Data Directory**: Create a local directory for Promtail to store its position files:
    ```bash
    mkdir -p data/promtail
    ```
5.  **Start Promtail**:
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
- Promtail discovers Docker containers via the `/var/run/docker.sock` socket and tails files under `/var/lib/docker/containers`.
- Labels attached by this config: `instance_id`, `instance_ip`, `container`, `compose_project`, `compose_service`, `log_stream`.
- The push endpoint requires HTTPS and Basic Auth at the proxy; credentials are set via `.env`.
- In Grafana, use the "Docker Logs" dashboard and filter by the remote `compose_project`/`compose_service` values to view these logs.


easy to run:
sudo /mnt/filesystem-o0/monitoring/remote/deploy-promtail.sh <grose-