#!/bin/bash
# One-shot build + run for the Teleport server.
#
# Build + run both happen inside `docker compose up --build`: the Dockerfile
# is two-stage — stage 1 installs the pinned Go/Rust/Node toolchain and
# compiles the fork, stage 2 is a thin runtime image with just the compiled
# binaries. Toolchain installs go through Ubuntu's own apt + vendor-direct
# downloads (go.dev, rustup.rs, nodejs.org via nvm), not Debian's mirror
# network — deliberately avoids a known connectivity problem some networks
# have reaching deb.debian.org.
#
# Supervision: docker-compose.yml sets `restart: unless-stopped` — that's
# the crash/reboot recovery, no systemd unit needed for Teleport itself.
#
# Usage: bash build-and-run.sh   (do NOT run with sudo — see note below)
# Re-run anytime after a code change in teleport/ to rebuild + redeploy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log()  { echo "==> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] && die "Don't run this with sudo — just: bash build-and-run.sh (needs the docker group, not root)."


log "[1/6] Checking .env"
if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
    cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
    log "  Created .env from .env.example — edit it then re-run."
    exit 0
fi

log "[2/6] Building + starting Teleport (first run: ~15-20 min; later runs reuse Docker's layer + BuildKit cache mounts for the Go build)"
cd "$SCRIPT_DIR"
docker compose up -d --build

log "  Waiting for Teleport to be healthy..."
# shellcheck source=/dev/null
source "$SCRIPT_DIR/.env"
for i in $(seq 1 90); do
    if curl -sk "https://localhost:${WEB_PORT:-3080}/webapi/ping" | grep -q '"auth"'; then
        break
    fi
    sleep 10
    [[ $i -eq 90 ]] && die "Teleport did not start after 15min. Check: docker compose logs"
done
log "  Teleport is up"

TCTL="docker compose exec -T teleport tctl"

log "[3/6] Applying roles"
bash "$SCRIPT_DIR/apply-roles.sh"

log "[4/6] Checking admin user"
if $TCTL get "user/${ADMIN_USER}" &>/dev/null; then
    log "  $ADMIN_USER already exists, skipping create-admin.sh"
else
    bash "$SCRIPT_DIR/create-admin.sh"
fi

log "[5/6] Baking current cluster values into ../vs/setup.sh + refreshing ssh-access-watcher identity"
bash "$SCRIPT_DIR/bake.sh"

log "[6/6] Installing ssh-access-watcher (needs root — will prompt for sudo)"
sudo bash "$SCRIPT_DIR/automation/ssh-access-watcher/install.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Teleport running in Docker (restart: unless-stopped)"
echo " Web UI: https://${PUBLIC_ADDR:-localhost:3080}"
echo " Logs:   docker compose logs -f"
echo ""
echo " VS install is one-shot too — copy ../vs/setup.sh to a VS machine:"
echo "   scp ../vs/setup.sh user@vs-machine:~/"
echo "   sudo bash setup.sh <vs-name>"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
