## Hub Poller

This repo now includes a lightweight service that periodically polls a list of hubs and emits structured JSON logs to Loki via Promtail. These logs include per-node state, errors, and model-specific metrics like `poc_weight`.

Quick start:

1. Define hubs in `hubs/hubs.yml` (see `hubs/hubs.example.yml`).
2. Set env vars in `env.monitoring` for hub poll intervals.
3. `docker compose up -d`.

The Grafana dashboard "Hub Nodes" is provisioned automatically and can be filtered by hub and node.

# GNK Monitoring

This repository contains the configuration for a monitoring stack based on Grafana, Loki, and Promtail.

## Setup

1.  Create an `env.monitoring` file from the `env.monitoring.template`.
2.  Fill in the required variables in `env.monitoring`.
3.  Run `docker-compose up -d` to start the monitoring stack.

## Environment Variables

The following environment variables need to be set in `env.monitoring`:

-   `COMPOSE_PROJECT_NAME`: The name of the docker-compose project.
-   `GF_SERVER_ROOT_IP`: The root IP for the Grafana server.
-   `GRAFANA_ADMIN_USER`: The admin username for Grafana.
-   `GRAFANA_ADMIN_PASSWORD`: The admin password for Grafana.
-   `LOKI_INGEST_USER`: The user for Loki ingestion.
-   `LOKI_INGEST_PASS_HASH`: The hashed password for the Loki user.

For the remote promtail setup, you will need to create a `.env` file in the `remote` directory based on `.env_template`.

## Components

- Promtail agents (host and remotes) shipping logs to Loki.
- Metrics collector containers emitting CPU/RAM/process/GPU samples as JSON for Promtail to ship.
- Connectivity checker running ping/HTTP probes defined by templates with per-node substitution.
- Grafana dashboards: "System Overview" for metrics and "Connectivity Monitor" for connectivity logs.
