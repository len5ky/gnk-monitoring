# Deployment Guide for Monitoring Stack

This guide provides the steps to deploy the self-hosted monitoring stack (Loki, Promtail, Grafana, Caddy, connectivity checker, metrics collectors) on a new host machine.

## 1. Prerequisites

- **Docker & Docker Compose**: Ensure `docker` and `docker-compose` (or `docker compose`) are installed on the new host.
- **Project Files**: The `monitoring` project directory is required.
- **Public IP**: You need a static public IP address for the new host.

## 2. Initial Setup

### Step 2.1: Copy Project Files
Transfer the entire `monitoring` directory to the new host. You can use `scp`, `rsync`, or clone it from your version control system.

Example using `scp` (run from your local machine):
```bash
scp -r /path/to/your/monitoring user@<NEW_HOST_IP>:/path/to/destination/
```

### Step 2.2: Configure Environment
Navigate into the `monitoring` directory on the new host.

Create an environment configuration file by copying the template.
```bash
cp env.monitoring.template env.monitoring
```
Now, edit `.env.monitoring` and set the following variables:
- `GRAFANA_ADMIN_PASSWORD`: Set a new secure password for the Grafana admin user.
- `GF_SERVER_ROOT_IP`: **Crucially, replace `REPLACE_WITH_NEW_HOST_IP` with the new host's actual public IP address.**
- `HOST_INSTANCE_ID`: Unique identifier for the monitoring host used in dashboards.
- `LOKI_INGEST_PASS_HASH`: The pre-set hash corresponds to the password `ZHz09YGEGYALa7Kpt5e2xVkw`. To generate a new one, run the following and paste the output here (remember to escape `$` with `$$`):
  ```bash
  docker run --rm caddy:2 caddy hash-password --plaintext 'your-new-password'
  ```
### Step 2.3: Configure Connectivity Inventory

The connectivity checker reads an inventory and profiles. Copy the examples to a mutable location (e.g., `connectivity-checker/config`) and update them with your nodes and templates. The host stack mounts this directory read-only.

### Step 2.3: Generate TLS Certificate for New IP
The stack uses a self-signed TLS certificate for Caddy to provide HTTPS. You must generate a new one matching the new host's IP.

Run the following command, replacing `<NEW_HOST_IP>` with your actual public IP:
./scripts/create_cert.sh

### Step 2.4: Update Caddyfile
The `Caddyfile` does not need changes as it's configured to listen on all interfaces. The certificate generation in the previous step is sufficient.

### Step 2.5: Set Data Directory Permissions
Grafana and Loki containers run with dedicated non-root users. To prevent permission errors on startup, you must set the correct ownership for the host directories they use for data storage.

Run the following commands:
```bash
sudo chown -R 472:472 ./data/grafana
sudo chown -R 10001:10001 ./data/loki
```

## 3. Deploy the Stack

With configuration complete, you can start all services using the provided script:
```bash
./scripts/start.sh
```
This command will pull the necessary Docker images and start all containers in the background.

## 4. Verification

### Step 4.1: Check Container Status
Check that all containers are running and healthy:
```bash
./scripts/status.sh
```
You should see `grafana`, `loki`, `promtail`, `caddy`, `metrics-collector`, `connectivity-checker`, and `hub-poller` services running.

### Step 4.2: Access Services
- **Grafana**: Access Grafana via `https://<NEW_HOST_IP>:8445`.
  - You will see a browser warning because the certificate is self-signed. This is expected. Proceed to the site.
  - Login with user `admin` and the password you set in `.env.monitoring`.
- **Loki**: The Loki API is available at `https://<NEW_HOST_IP>:8446`. This endpoint is protected by Basic Auth.

## 5. Connecting Remote Promtail Nodes

For each remote node that needs to send logs and metrics to this monitoring host:
1.  Follow the instructions in the `remote/README.md` file.
2.  When creating the `.env` file on the remote node, ensure you set:
    - `LOKI_INGEST_PASSWORD` to the password you chose.
    - `GF_SERVER_ROOT_IP` for Promtail TLS hostname verification.
    - Optional `NETWORKNODE_IP` override if the node should target a different connectivity endpoint.
3.  Populate the node inventory and profile templates for the connectivity checker so each remote uses `${NETWORKNODE_IP}` substitution.
4.  Use the Grafana dashboards "System Overview" and "Connectivity Monitor" to verify data.
