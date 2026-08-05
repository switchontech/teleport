#!/bin/bash
# Pushes all role definitions in roles/*.yaml to the running Teleport cluster.
# Re-run standalone any time a role yaml is edited.
#
# Idempotent — safe to run multiple times.
#
# Usage: bash apply-roles.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROLES_DIR="$SCRIPT_DIR/roles"

if docker compose -f "$SCRIPT_DIR/docker-compose.yml" ps teleport 2>/dev/null | grep -q "running\|healthy"; then
    TCTL="docker compose -f $SCRIPT_DIR/docker-compose.yml exec -T teleport tctl"
else
    TCTL="tctl"
fi

for role_file in "$ROLES_DIR"/*.yaml; do
    [[ -f "$role_file" ]] || continue
    echo "==> Applying $(basename "$role_file")"
    $TCTL create -f - < "$role_file"
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Roles applied."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
