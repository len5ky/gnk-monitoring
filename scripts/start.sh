#!/usr/bin/env bash
set -euo pipefail

# Change to the project root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

# Verify env file exists
if [ ! -f "env.monitoring" ]; then
    echo "Error: env.monitoring file not found in $PROJECT_ROOT"
    echo "Please create it from env.monitoring.template"
    exit 1
fi

echo "Checking password hashes..."

# Function to generate bcrypt hash using Caddy
generate_hash() {
    local password="$1"
    docker run --rm caddy:2 caddy hash-password --plaintext "$password" 2>/dev/null
}

# Load current env file
source env.monitoring

# Auto-generate LOKI_INGEST_PASS_HASH if missing
if [ -n "${LOKI_INGEST_PASSWORD:-}" ] && [ -z "${LOKI_INGEST_PASS_HASH:-}" ]; then
    echo "Generating Loki password hash..."
    LOKI_HASH=$(generate_hash "$LOKI_INGEST_PASSWORD")
    # Update the env.monitoring file
    if grep -q "^LOKI_INGEST_PASS_HASH=" env.monitoring; then
        sed -i "s|^LOKI_INGEST_PASS_HASH=.*|LOKI_INGEST_PASS_HASH=$LOKI_HASH|" env.monitoring
    else
        echo "LOKI_INGEST_PASS_HASH=$LOKI_HASH" >> env.monitoring
    fi
    echo "✓ Loki password hash generated"
fi

# Auto-generate PROMETHEUS_PASS_HASH if missing
if [ -n "${PROMETHEUS_PASSWORD:-}" ] && [ -z "${PROMETHEUS_PASS_HASH:-}" ]; then
    echo "Generating Prometheus password hash..."
    PROM_HASH=$(generate_hash "$PROMETHEUS_PASSWORD")
    # Update the env.monitoring file
    if grep -q "^PROMETHEUS_PASS_HASH=" env.monitoring; then
        sed -i "s|^PROMETHEUS_PASS_HASH=.*|PROMETHEUS_PASS_HASH=$PROM_HASH|" env.monitoring
    else
        echo "PROMETHEUS_PASS_HASH=$PROM_HASH" >> env.monitoring
    fi
    echo "✓ Prometheus password hash generated"
fi

echo "Starting monitoring stack from: $PROJECT_ROOT"
docker compose --env-file env.monitoring up -d

