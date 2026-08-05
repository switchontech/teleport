#!/bin/bash
# Fully removes everything setup.sh installed: Teleport (package, config,
# ALL local data/identity), x11vnc, websockify, noVNC, systemd services.
# Leaves the machine clean enough that re-running setup.sh always works,
# even after a server-side cluster rebuild (new CA, wiped cluster data) —
# no stale identity/cert state survives this script.
#
# Usage: sudo bash uninstall.sh

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root. Use: sudo bash uninstall.sh"; exit 1; }

# Detect the desktop user the same way setup.sh did.
DESKTOP_USER=""
for session in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
    session_state=$(loginctl show-session "$session" -p State --value 2>/dev/null || true)
    session_type=$(loginctl show-session "$session" -p Type --value 2>/dev/null || true)
    if [[ "$session_state" == "active" && ( "$session_type" == "x11" || "$session_type" == "wayland" ) ]]; then
        DESKTOP_USER=$(loginctl show-session "$session" -p Name --value 2>/dev/null || true)
        break
    fi
done
if [[ -z "$DESKTOP_USER" ]]; then
    DESKTOP_USER="${SUDO_USER:-$USER}"
fi
DESKTOP_HOME=$(eval echo "~$DESKTOP_USER")
USER_ID=$(id -u "$DESKTOP_USER")
export XDG_RUNTIME_DIR="/run/user/${USER_ID}"

echo "=== [1/4] Stopping and removing user services (x11vnc, websockify) ==="
sudo -u "$DESKTOP_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    systemctl --user stop x11vnc websockify 2>/dev/null || true
sudo -u "$DESKTOP_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    systemctl --user disable x11vnc websockify 2>/dev/null || true
sudo -u "$DESKTOP_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    systemctl --user daemon-reload 2>/dev/null || true

rm -f "$DESKTOP_HOME/.config/systemd/user/x11vnc.service"
rm -f "$DESKTOP_HOME/.config/systemd/user/websockify.service"
rm -f /usr/local/bin/x11vnc-start.sh

echo "=== [2/4] Stopping and removing Teleport ==="
systemctl stop teleport 2>/dev/null || true
systemctl disable teleport 2>/dev/null || true

# Full wipe: config, ALL local data (certs, identity, cluster state cache),
# stale pid file, and the whole systemd drop-in dir — not just the config
# file, so nothing stale can survive to confuse a future rejoin.
rm -f /etc/teleport.yaml
rm -rf /var/lib/teleport
rm -f /run/teleport.pid
rm -rf /etc/systemd/system/teleport.service.d
systemctl daemon-reload

echo "=== [3/4] Purging Teleport package ==="
apt-get purge -y teleport 2>/dev/null || true

echo "=== [4/4] Purging x11vnc, noVNC, websockify ==="
apt-get purge -y x11vnc novnc python3-websockify psmisc 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

echo ""
echo "=============================="
echo "VS uninstall complete."
echo "Run setup.sh to reinstall."
echo "=============================="
