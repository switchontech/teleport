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
cp "$SCRIPT_DIR/ssh-access-watcher.service" /etc/systemd/system/ssh-access-watcher.service
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
