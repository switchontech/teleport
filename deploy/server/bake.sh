#!/bin/bash
# Bakes the live cluster values (proxy address, join token, CA pin) into
# ../vs/setup.sh so it's ready to send to a VS machine. Also refreshes the
# ssh-access-watcher identity file, which goes stale under the same
# condition (cluster CA change).
#
# Re-run only if PUBLIC_ADDR, join token, or cluster CA changes
# (cluster CA changes only when the data volume is wiped). Not needed
# on regular docker compose restarts.
#
# Usage:
#   bash bake.sh
#
# Then send the file to the VS and run:
#   scp ../vs/setup.sh user@vs-machine:~/
#   sudo bash setup.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_SH="$SCRIPT_DIR/../vs/setup.sh"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

if docker compose -f "$COMPOSE_FILE" ps teleport 2>/dev/null | grep -q "running\|healthy"; then
    TCTL="docker compose -f $COMPOSE_FILE exec -T teleport tctl"
    CFG_CAT="docker compose -f $COMPOSE_FILE exec -T teleport cat /etc/teleport.yaml"
else
    TCTL="tctl"
    CFG_CAT="cat /etc/teleport.yaml"
fi

CA_PIN=$($TCTL status 2>/dev/null | grep -oP 'sha256:[a-f0-9]+' | head -1)
[[ -z "$CA_PIN" ]] && { echo "ERROR: could not get CA pin. Is teleport running?"; exit 1; }

# ssh-access-watcher authenticates with a signed identity file, not a join
# token — that identity is only valid against the CA that signed it, so any
# time the cluster CA changes (fresh teleport_data volume) it goes stale the
# same way a VS's cached identity would. Refresh it here since this script
# already knows how to reach tctl and already runs on every CA change.
WATCHER_DIR="$SCRIPT_DIR/automation/ssh-access-watcher"
echo "==> Refreshing ssh-access-watcher identity"
if ! $TCTL get user/ssh-access-watcher &>/dev/null; then
    $TCTL users add ssh-access-watcher --roles=ssh-access-watcher --logins=ssh-access-watcher >/dev/null
fi
mkdir -p "$WATCHER_DIR/secrets"
if docker compose -f "$COMPOSE_FILE" ps teleport 2>/dev/null | grep -q "running\|healthy"; then
    # tctl runs inside the container here — --out writes into the
    # container's own filesystem, not the host, so sign to a container-local
    # tmp path and docker cp it out to the host-side secrets/ dir.
    CONTAINER_ID=$(docker compose -f "$COMPOSE_FILE" ps -q teleport)
    $TCTL auth sign --user=ssh-access-watcher --format=file --out=/tmp/watcher-identity --ttl=8760h --overwrite
    docker cp "$CONTAINER_ID:/tmp/watcher-identity" "$WATCHER_DIR/secrets/identity"
    docker compose -f "$COMPOSE_FILE" exec -T teleport rm -f /tmp/watcher-identity
else
    $TCTL auth sign --user=ssh-access-watcher --format=file --out="$WATCHER_DIR/secrets/identity" --ttl=8760h --overwrite
fi
chmod 600 "$WATCHER_DIR/secrets/identity"

STATIC_TOKEN=$($CFG_CAT 2>/dev/null | grep -oP '(?<=node,app:)[^"\s]+' | head -1)
[[ -z "$STATIC_TOKEN" ]] && { echo "ERROR: no static node,app token in teleport config"; exit 1; }

if [[ -f "$SCRIPT_DIR/.env" ]]; then
    source "$SCRIPT_DIR/.env"
fi
if [[ -n "${PUBLIC_ADDR:-}" ]]; then
    PROXY="$PUBLIC_ADDR"
else
    PUB_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    PROXY="${PUB_IP}:3080"
fi

sed -i \
    -e "s|^PROXY=.*|PROXY=\"${PROXY}\"|" \
    -e "s|^TOKEN=.*|TOKEN=\"${STATIC_TOKEN}\"|" \
    -e "s|^CA_PIN=.*|CA_PIN=\"${CA_PIN}\"|" \
    "$SETUP_SH"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ../vs/setup.sh baked"
echo " Proxy:  $PROXY"
echo " Token:  $STATIC_TOKEN"
echo " CA Pin: $CA_PIN"
echo ""
echo " Send to VS, then run:"
echo "   scp ../vs/setup.sh user@vs-machine:~/"
echo "   sudo bash setup.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
