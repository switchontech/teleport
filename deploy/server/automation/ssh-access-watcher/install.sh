#!/bin/bash
# Builds the watcher as a static binary and installs it as a systemd service
# on this host. Re-run any time main.go changes — safe to run repeatedly.
#
# Usage: sudo bash install.sh

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root. Use: sudo bash install.sh"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

GO_VERSION="go1.25.11"

# sudo resets PATH, so a go installed under the invoking user's PATH
# (e.g. via .bashrc) may not be visible here even though `go version`
# works outside sudo. Fall back to the standard install location.
GO_BIN=$(command -v go || true)
if [[ -z "$GO_BIN" && -x /usr/local/go/bin/go ]]; then
    GO_BIN=/usr/local/go/bin/go
fi

if [[ -z "$GO_BIN" ]]; then
    echo "=== Installing Go $GO_VERSION (not found on this host) ==="
    GOTARBALL="/tmp/${GO_VERSION}.linux-amd64.tar.gz"
    wget -q "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" -O "$GOTARBALL"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "$GOTARBALL"
    rm -f "$GOTARBALL"
    GO_BIN=/usr/local/go/bin/go
fi

echo "=== Building static binary ==="
CGO_ENABLED=0 "$GO_BIN" build -C "$SCRIPT_DIR" -o /usr/local/bin/ssh-access-watcher .

echo "=== Installing identity ==="
mkdir -p /etc/ssh-access-watcher
install -m 600 "$SCRIPT_DIR/secrets/identity" /etc/ssh-access-watcher/identity

echo "=== Installing systemd unit ==="
# Generated here rather than shipped as a companion file — keeps this
# script self-contained (nothing to forget committing) and lets the role
# file path below resolve correctly regardless of whose machine/home dir
# this repo is checked out under.
ROLES_DIR="$(cd "$SCRIPT_DIR/../../roles" && pwd)"
cat > /etc/systemd/system/ssh-access-watcher.service <<EOF
[Unit]
Description=ssh-access-watcher — auto-appends new VS logins to the ssh-access Teleport role
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/ssh-access-watcher
Environment=TELEPORT_PROXY_ADDR=127.0.0.1:3025
Environment=TELEPORT_IDENTITY_FILE=/etc/ssh-access-watcher/identity
Environment=SSH_ACCESS_ROLE_FILE=${ROLES_DIR}/ssh-access.yaml
Restart=always
RestartSec=5
User=root
NoNewPrivileges=true
ProtectSystem=strict
ReadOnlyPaths=/etc/ssh-access-watcher
ReadWritePaths=${ROLES_DIR}

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable ssh-access-watcher
# "enable --now" is a no-op if the service is already running, so it won't
# pick up a rebuilt binary on its own — restart explicitly every time.
systemctl restart ssh-access-watcher

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ssh-access-watcher installed and started."
echo " Check status: systemctl status ssh-access-watcher"
echo " Follow logs:  journalctl -u ssh-access-watcher -f"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
