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
    PROMETHEUS_USER=$(grep -E '^PROMETHEUS_USER=' "$ENV_FILE" | cut -d'=' -f2-)
    PROMETHEUS_PASSWORD=$(grep -E '^PROMETHEUS_PASSWORD=' "$ENV_FILE" | cut -d'=' -f2-)
else
    echo "Error: secrets template not found at ${ENV_FILE}"
    exit 1
fi

NETWORKNODE_IP="${NETWORKNODE_IP:-$GF_SERVER_ROOT_IP}"
PROMETHEUS_USER="${PROMETHEUS_USER:-prometheus}"

if [ -z "${LOKI_INGEST_USER:-}" ] || [ -z "${LOKI_INGEST_PASSWORD:-}" ] || [ -z "${GF_SERVER_ROOT_IP:-}" ]; then
    echo "Error: Missing one or more required variables in ${ENV_FILE} (LOKI_INGEST_USER, LOKI_INGEST_PASSWORD, GF_SERVER_ROOT_IP)"
    exit 1
fi

if [ -z "${PROMETHEUS_PASSWORD:-}" ]; then
    echo "Error: PROMETHEUS_PASSWORD is required in ${ENV_FILE}"
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
mkdir -p "${LOCAL_SETUP_DIR}/data/logs"

# Create .env file for docker-compose
echo "Creating docker-compose .env file..."
cat > "${LOCAL_SETUP_DIR}/.env" <<EOF
GF_SERVER_ROOT_IP=${GF_SERVER_ROOT_IP}
LOKI_INGEST_USER=${LOKI_INGEST_USER}
LOKI_INGEST_PASSWORD=${LOKI_INGEST_PASSWORD}
NETWORKNODE_IP=${NETWORKNODE_IP}
INSTANCE_ID=${INSTANCE_ID}
INSTANCE_IP=${INSTANCE_IP}
PROMETHEUS_USER=${PROMETHEUS_USER}
PROMETHEUS_PASSWORD=${PROMETHEUS_PASSWORD}
SHARED_REMOTE_DIR=${SHARED_REMOTE_DIR}
EOF

# Create Grafana Agent config for pushing metrics
echo "Creating Grafana Agent configuration file..."
rm -rf "${LOCAL_SETUP_DIR}/grafana-agent-config.yml"
cat > "${LOCAL_SETUP_DIR}/grafana-agent-config.yml" <<'AGENT_EOF'
server:
  log_level: info

metrics:
  global:
    scrape_interval: 15s
    external_labels:
      cluster: 'gnk-monitoring'
      instance_id: '${INSTANCE_ID}'
      instance_role: 'remote'
      instance_ip: '${INSTANCE_IP}'

  configs:
    - name: agent
      remote_write:
        - url: https://${GF_SERVER_ROOT_IP}:8448/api/v1/write
          basic_auth:
            username: ${PROMETHEUS_USER}
            password: ${PROMETHEUS_PASSWORD}
          tls_config:
            insecure_skip_verify: true

      scrape_configs:
        # Scrape node-exporter (localhost only - not exposed)
        - job_name: 'node-exporter'
          static_configs:
            - targets: ['127.0.0.1:9100']
              labels:
                instance_id: '${INSTANCE_ID}'
                instance_role: 'remote'

        # Scrape nvidia-gpu-exporter (localhost only - not exposed)
        - job_name: 'nvidia-gpu-exporter'
          static_configs:
            - targets: ['127.0.0.1:9835']
              labels:
                instance_id: '${INSTANCE_ID}'
                instance_role: 'remote'
AGENT_EOF

# Create promtail config with authentication
echo "Creating promtail configuration file..."
# Remove any existing file or directory (from old symlinks)
rm -rf "${LOCAL_SETUP_DIR}/promtail-config.yml"
cat > "${LOCAL_SETUP_DIR}/promtail-config.yml" <<'PROMTAIL_EOF'
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: https://${GF_SERVER_ROOT_IP}:8446/loki/api/v1/push
    basic_auth:
      username: ${LOKI_INGEST_USER}
      password: ${LOKI_INGEST_PASSWORD}
    tls_config:
      insecure_skip_verify: true

scrape_configs:
  - job_name: docker
    pipeline_stages:
      - docker: {}
      - json:
          expressions:
            kind: kind
            status: status
            instance_id: instance_id
            instance_role: instance_role
            node: node
            name: name
      - regex:
          expression: '^\d{1,2}:\d{2}(?:AM|PM)\s+(?P<extracted_level>ERR|INF|WRN|CRT)\b'
      - regex:
          expression: '(?i)(?:level=|\b)(?P<extracted_level>trace|debug|dbg|info|inf|warn|warning|wrn|error|err|critical|crit)\b'
      - regex:
          expression: '(?P<is_health_check>GET .*?/(?:health|state)\s+HTTP)'
      - template:
          source: level
          template: '{{ .extracted_level | default "unknown" | lower }}'
      - template:
          source: health_check
          template: '{{ if .is_health_check }}true{{ else }}false{{ end }}'
      - labels:
          kind:
          status:
          instance_id:
          instance_role:
          node:
          name:
          level:
          health_check:
    docker_sd_configs:
      - host: unix:///var/run/docker.sock
        refresh_interval: 5s
    relabel_configs:
      - source_labels: ['__meta_docker_container_name']
        regex: '.+'
        action: keep
      - source_labels: ['__meta_docker_container_id']
        target_label: '__path__'
        replacement: /var/lib/docker/containers/$1/$1-json.log
      - source_labels: ['__meta_docker_container_name']
        target_label: 'container'
        regex: '/(.*)'
      - source_labels: ['__meta_docker_container_label_com_docker_compose_project']
        target_label: 'compose_project'
      - source_labels: ['__meta_docker_container_label_com_docker_compose_service']
        target_label: 'compose_service'
      - source_labels: ['__meta_docker_container_log_stream']
        target_label: 'log_stream'
      - replacement: 'docker'
        target_label: 'job'
      - replacement: '${INSTANCE_ID}'
        target_label: 'instance_id'
      - replacement: '${INSTANCE_IP}'
        target_label: 'instance_ip'
PROMTAIL_EOF
ln -sfn "${SHARED_REMOTE_DIR}/connectivity" "${LOCAL_SETUP_DIR}/connectivity"
ln -sfn "${SHARED_REMOTE_DIR}/../connectivity-checker" "${LOCAL_SETUP_DIR}/connectivity-checker"
 
# Copy and patch docker-compose.yml to adjust build contexts for remote deployment
COMPOSE_FILE_LOCAL="${LOCAL_SETUP_DIR}/docker-compose.yml"
echo "Copying and patching docker-compose file for remote context..."
cp "${SHARED_REMOTE_DIR}/docker-compose.yml" "${COMPOSE_FILE_LOCAL}"
sed -i \
    -e 's|context: ../connectivity-checker|context: ./connectivity-checker|g' \
    "${COMPOSE_FILE_LOCAL}"

# Check if nvidia-smi is available
if command -v nvidia-smi &> /dev/null; then
    echo "✓ NVIDIA GPU detected - nvidia-gpu-exporter will be enabled"
    COMPOSE_FILES="-f ${COMPOSE_FILE_LOCAL}"
else
    echo "⚠ No NVIDIA GPU detected - disabling nvidia-gpu-exporter"
    # Remove the nvidia-gpu-exporter service from docker-compose
    cat > "${LOCAL_SETUP_DIR}/docker-compose.override.yml" <<EOF
version: "3.9"
services:
  nvidia-gpu-exporter:
    deploy:
      replicas: 0
EOF
    COMPOSE_FILES="-f ${COMPOSE_FILE_LOCAL} -f ${LOCAL_SETUP_DIR}/docker-compose.override.yml"
fi

# Stop and remove any existing container first to avoid state issues
echo "Stopping and removing existing containers (if any)..."
$COMPOSE_CMD \
    ${COMPOSE_FILES} \
    --project-directory "${LOCAL_SETUP_DIR}" \
    rm -f -s

# Start services with docker compose
echo "Starting containers via docker-compose..."
$COMPOSE_CMD \
    ${COMPOSE_FILES} \
    --project-directory "${LOCAL_SETUP_DIR}" \
    up -d --build

echo "---"
echo "Promtail agent started successfully."
echo "To check status, run: "
echo "  $COMPOSE_CMD --project-directory ${LOCAL_SETUP_DIR} ps"
echo "To view logs, run: "
echo "  $COMPOSE_CMD --project-directory ${LOCAL_SETUP_DIR} logs -f"
