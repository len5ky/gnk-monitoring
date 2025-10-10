#! /bin/bash
cd "$(dirname "$0")/.."
source ./env.monitoring
mkdir -p ./config/caddy/certs
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout ./config/caddy/certs/ip.key \
  -out ./config/caddy/certs/ip.crt \
  -days 3650 \
  -subj "/CN=$GF_SERVER_ROOT_IP" \
  -addext "subjectAltName = IP:$GF_SERVER_ROOT_IP"
