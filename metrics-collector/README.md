# Metrics Collector

Simple Python script that emits CPU, memory, process sample, and optional GPU
stats as JSON. Promtail can pick up the stdout stream.

Run this service alongside Promtail (host or remote) using environment variables
for interval and process sampling limits.

Environment variables / flags:

- `METRICS_INTERVAL` – seconds between samples (default 15)
- `METRICS_GPU` – set `true` to include `nvidia-smi` data
- `METRICS_PROCESS_LIMIT` – number of `/proc` samples to include
- `INSTANCE_ID`, `INSTANCE_ROLE` – attached to the JSON output

