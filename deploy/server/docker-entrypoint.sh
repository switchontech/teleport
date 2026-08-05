#!/bin/bash
set -euo pipefail

# Binaries are already baked into the image (see Dockerfile) — this script
# only generates config from env vars and starts Teleport. No compiling here.

PUBLIC_ADDR="${PUBLIC_ADDR:-localhost:3080}"
PUBLIC_HOST="${PUBLIC_ADDR%%:*}"
TUNNEL_PORT="${TUNNEL_PORT:-3024}"
CLUSTER_NAME="${CLUSTER_NAME:-switchon.teleport}"
NODENAME="${NODENAME:-teleport}"
VS_JOIN_TOKEN="${VS_JOIN_TOKEN:-vs-join-token-switchon}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
TELEPORT_EXTRA_ARGS="${TELEPORT_EXTRA_ARGS:-}"
DATA_DIR="/var/lib/teleport"

mkdir -p "$DATA_DIR"

cat > /etc/teleport.yaml <<EOF
version: v3
teleport:
  nodename: ${NODENAME}
  data_dir: ${DATA_DIR}
  log:
    output: stderr
    severity: ${LOG_LEVEL}

auth_service:
  enabled: true
  cluster_name: ${CLUSTER_NAME}
  tokens:
    - "node,app:${VS_JOIN_TOKEN}"

proxy_service:
  enabled: true
  web_listen_addr: "0.0.0.0:3080"
  public_addr: "${PUBLIC_ADDR}"
  tunnel_listen_addr: "0.0.0.0:${TUNNEL_PORT}"
  tunnel_public_addr: "${PUBLIC_HOST}:${TUNNEL_PORT}"

ssh_service:
  enabled: false
EOF

echo "==> Config generated: cluster=${CLUSTER_NAME} public_addr=${PUBLIC_ADDR} log=${LOG_LEVEL}"
echo "==> Starting Teleport..."

# shellcheck disable=SC2086
exec /usr/local/bin/teleport start --config /etc/teleport.yaml ${TELEPORT_EXTRA_ARGS}
