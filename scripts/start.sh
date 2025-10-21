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

echo "Starting monitoring stack from: $PROJECT_ROOT"
docker compose --env-file env.monitoring up -d

