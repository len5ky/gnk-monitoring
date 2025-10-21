## Hub Poller

This repo now includes a lightweight service that periodically polls a list of hubs and emits structured JSON logs to Loki via Promtail. These logs include per-node state, errors, and model-specific metrics like `poc_weight`.

Quick start:

1. Define hubs in `hubs/hubs.yml` (see `hubs/hubs.example.yml`).
2. Set env vars in `env.monitoring` for hub poll intervals.
3. `docker compose up -d`.

The Grafana dashboard "Hub Nodes" is provisioned automatically and can be filtered by hub and node.

# GNK Monitoring

This repository contains the configuration for a monitoring stack based on Grafana, Loki, Prometheus, and Promtail.

## Quick Start

1.  Create an `env.monitoring` file from the `env.monitoring.template`.
2.  Fill in the required variables (use plaintext passwords - hashes auto-generated).
3.  Run `./scripts/start.sh` to start the monitoring stack.

## Environment Variables

The following environment variables need to be set in `env.monitoring`:

-   `COMPOSE_PROJECT_NAME`: The name of the docker-compose project.
-   `HOST_INSTANCE_ID`: Unique identifier for the monitoring host.
-   `GF_SERVER_ROOT_IP`: The root IP for the Grafana server.
-   `GRAFANA_ADMIN_USER`: The admin username for Grafana.
-   `GRAFANA_ADMIN_PASSWORD`: The admin password for Grafana.
-   `LOKI_INGEST_USER`: The user for Loki ingestion.
-   `LOKI_INGEST_PASSWORD`: The plaintext password for Loki (hash auto-generated).
-   `PROMETHEUS_USER`: The user for Prometheus remote_write.
-   `PROMETHEUS_PASSWORD`: The plaintext password for Prometheus (hash auto-generated).

For the remote setup, you will need to create a `.env` file in the `remote` directory based on `.env_template`.

## Components

### Logs (Loki + Promtail)
- Promtail agents (host and remotes) shipping logs to Loki.
- Connectivity checker running ping/HTTP probes defined by templates with per-node substitution.
- Grafana dashboards: "Connectivity Monitor" for connectivity logs, "Hub Nodes" for hub polling.

### Metrics (Prometheus + Grafana Agent)
- **Host**: Prometheus server receives metrics via remote_write (push-based).
- **Host**: node-exporter collects local system metrics (CPU, RAM, disk, network).
- **Remote**: Grafana Agent scrapes local exporters and pushes to Prometheus.
- **Remote**: node-exporter (localhost-only) collects system metrics.
- **Remote**: nvidia-gpu-exporter (localhost-only, GPU nodes) collects GPU metrics.
- Grafana dashboard: "System Metrics (Node Exporter)" for system resources.

### Security Features
- **No exposed ports on remote nodes**: Exporters bind to 127.0.0.1 only.
- **Push-based architecture**: Remote nodes push metrics via HTTPS + auth.
- **TLS encryption**: All external communication uses HTTPS with self-signed certs.
- **Authentication**: Basic auth for Loki ingestion and Prometheus remote_write.
- **No firewall rules needed**: Remote nodes only need outbound connections.

## Architecture

```
Monitoring Host:
├─ Grafana (UI) - Port 8445 (HTTPS)
├─ Loki (logs) - Port 8446 (HTTPS + auth)
├─ Prometheus (metrics) - Port 8448 (HTTPS + auth for remote_write)
├─ Caddy (reverse proxy) - Handles TLS and authentication
└─ node-exporter (local metrics)

Remote Nodes:
├─ Promtail → pushes logs → Loki
├─ Grafana Agent → scrapes local exporters → pushes to Prometheus
├─ node-exporter (127.0.0.1:9100) - System metrics
├─ nvidia-gpu-exporter (127.0.0.1:9835) - GPU metrics (if available)
└─ connectivity-checker → logs connectivity tests
```

## Ports Reference

### Monitoring Host (Open Ports)
- 8445: Grafana UI (HTTPS)
- 8446: Loki ingestion (HTTPS + auth)
- 8447: Prometheus UI (HTTPS + auth)
- 8448: Prometheus remote_write (HTTPS + auth)

### Remote Nodes (No Open Ports)
All exporters run on localhost only. Remote nodes push data outbound to monitoring host.
