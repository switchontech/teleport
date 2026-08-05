#!/bin/bash
# Creates the super-admin Teleport user and prints the signup URL.
# Called automatically by setup-teleport-dev.sh, or run standalone.
#
# Usage: bash create-admin.sh
# Reads ADMIN_USER / ADMIN_LOGINS from .env

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/.env"

if docker compose ps teleport 2>/dev/null | grep -q "running\|healthy"; then
    TCTL="docker compose exec -T teleport tctl"
else
    TCTL="tctl"
fi

echo "==> Creating super-admin user: $ADMIN_USER (roles: super-admin, ssh-access — logins: $ADMIN_LOGINS)"
INVITE_URL=$($TCTL users add "$ADMIN_USER" --roles=super-admin,ssh-access --logins="$ADMIN_LOGINS" 2>&1 | grep "https://")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Admin signup URL (valid 1h):"
echo "   $INVITE_URL"
echo ""
echo " Open in browser, accept the self-signed cert warning,"
echo " and complete registration."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
