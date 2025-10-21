#!/bin/bash

set -euo pipefail

# --- Configuration ---
# Local directory for Promtail agent setup
LOCAL_SETUP_DIR="/opt/promtail-agent"
# ---

# --- Helper Functions ---
function print_usage() {
    echo "Usage: $0 <instance-id>"
    echo "Deploys Promtail as a Docker container to forward logs to a central Loki instance."
    echo ""
    echo "Arguments:"
    echo "  <instance-id>   A unique identifier for this node (e.g., 'web-server-01')."
}

function check_deps() {
    if ! command -v docker &> /dev/null; then
        echo "Error: docker command not found. Please install Docker."
        exit 1
    fi
    # Check for 'docker compose' or 'docker-compose'
    if ! (docker compose version &> /dev/null || docker-compose version &> /dev/null); then
        echo "Error: docker-compose command not found. Please install Docker Compose."
        exit 1
    fi
    if ! command -v curl &> /dev/null; then
        echo "Warning: 'curl' not found. Unable to fetch public IP; will use local IP."
    fi
}

function get_compose_command() {
    if command -v docker-compose &> /dev/null; then
        echo "docker-compose"
    else
        echo "docker compose"
    fi
}


# --- Main Script ---

# Check for help flag
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print_usage
    exit 0
fi

# Validate input
if [ -z "${1:-}" ]; then
    echo "Error: Missing <instance-id> argument."
    print_usage
    exit 1
fi
INSTANCE_ID="$1"

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root to create directories in /opt." >&2
  exit 1
fi

check_deps
COMPOSE_CMD=$(get_compose_command)

# Determine directories and source secrets from .env file
SHARED_REMOTE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
ENV_FILE="${SHARED_REMOTE_DIR}/.env"

if [ -f "$ENV_FILE" ]; then
    echo "Reading settings from ${ENV_FILE}"
    LOKI_INGEST_USER=$(grep -E '^LOKI_INGEST_USER=' "$ENV_FILE" | cut -d'=' -f2-)
    LOKI_INGEST_PASSWORD=$(grep -E '^LOKI_INGEST_PASSWORD=' "$ENV_FILE" | cut -d'=' -f2-)
    GF_SERVER_ROOT_IP=$(grep -E '^GF_SERVER_ROOT_IP=' "$ENV_FILE" | cut -d'=' -f2-)
    NETWORKNODE_IP=$(grep -E '^NETWORKNODE_IP=' "$ENV_FILE" | cut -d'=' -f2-)
    METRICS_INTERVAL=$(grep -E '^METRICS_INTERVAL=' "$ENV_FILE" | cut -d'=' -f2-)
    METRICS_PROCESS_LIMIT=$(grep -E '^METRICS_PROCESS_LIMIT=' "$ENV_FILE" | cut -d'=' -f2-)
    METRICS_GPU=$(grep -E '^METRICS_GPU=' "$ENV_FILE" | cut -d'=' -f2-)
else
    echo "Error: secrets template not found at ${ENV_FILE}"
    exit 1
fi

NETWORKNODE_IP="${NETWORKNODE_IP:-$GF_SERVER_ROOT_IP}"

if [ -z "${LOKI_INGEST_USER:-}" ] || [ -z "${LOKI_INGEST_PASSWORD:-}" ] || [ -z "${GF_SERVER_ROOT_IP:-}" ]; then
    echo "Error: Missing one or more required variables in ${ENV_FILE} (LOKI_INGEST_USER, LOKI_INGEST_PASSWORD, GF_SERVER_ROOT_IP)"
    exit 1
fi

# Determine directories
# The directory where this script is located is the shared remote folder.
# Using BASH_SOURCE is better than $0 for sourced scripts.
echo "--- Promtail Agent Deployment ---"
echo "Instance ID:           ${INSTANCE_ID}"
echo "Shared Config Dir:     ${SHARED_REMOTE_DIR}"
echo "Local Setup Dir:       ${LOCAL_SETUP_DIR}"
echo "---------------------------------"

# Get instance IP
PUBLIC_IP=""
if command -v curl &> /dev/null; then
    PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me)
fi

if [ -n "$PUBLIC_IP" ]; then
    INSTANCE_IP=$PUBLIC_IP
    echo "Using public IP: ${INSTANCE_IP}"
else
    INSTANCE_IP=$(hostname -I | awk '{print $1}')
    echo "Using local IP: ${INSTANCE_IP}"
fi

if [ -z "$INSTANCE_IP" ]; then
    echo "Warning: Could not determine instance IP address."
    INSTANCE_IP="unknown"
fi

# Create local directories
echo "Creating local directories..."
mkdir -p "${LOCAL_SETUP_DIR}/data/promtail"

# Create .env file for docker-compose
echo "Creating docker-compose .env file..."
cat > "${LOCAL_SETUP_DIR}/.env" <<EOF
GF_SERVER_ROOT_IP=${GF_SERVER_ROOT_IP}
LOKI_INGEST_USER=${LOKI_INGEST_USER}
LOKI_INGEST_PASSWORD=${LOKI_INGEST_PASSWORD}
NETWORKNODE_IP=${NETWORKNODE_IP}
INSTANCE_ID=${INSTANCE_ID}
INSTANCE_IP=${INSTANCE_IP}
METRICS_INTERVAL=${METRICS_INTERVAL:-15}
METRICS_PROCESS_LIMIT=${METRICS_PROCESS_LIMIT:-20}
METRICS_GPU=${METRICS_GPU:-false}
EOF

# Symlink promtail config
echo "Linking promtail configuration file..."
ln -sf "${SHARED_REMOTE_DIR}/promtail-config.yml" "${LOCAL_SETUP_DIR}/promtail-config.yml"

# Stop and remove any existing container first to avoid state issues
echo "Stopping and removing existing promtail container (if any)..."
$COMPOSE_CMD \
    -f "${SHARED_REMOTE_DIR}/docker-compose.yml" \
    --project-directory "${LOCAL_SETUP_DIR}" \
    rm -f -s

# Start promtail with docker compose
echo "Starting promtail container via docker-compose..."
$COMPOSE_CMD \
    -f "${SHARED_REMOTE_DIR}/docker-compose.yml" \
    --project-directory "${LOCAL_SETUP_DIR}" \
    up -d

echo "---"
echo "Promtail agent started successfully."
echo "To check status, run: "
echo "  $COMPOSE_CMD --project-directory ${LOCAL_SETUP_DIR} ps"
echo "To view logs, run: "
echo "  $COMPOSE_CMD --project-directory ${LOCAL_SETUP_DIR} logs -f"
