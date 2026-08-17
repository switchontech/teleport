#!/bin/bash
# Fully removes everything setup.sh / setup-v3.sh / setup-v4.sh installed:
# Teleport (package, config, ALL local data/identity), x11vnc, websockify,
# noVNC, the v4 switch watcher, and every systemd unit involved.
# Leaves the machine clean enough that re-running any setup script always
# works, even after a server-side cluster rebuild (new CA, wiped cluster
# data) — no stale identity/cert state survives this script.
#
# Usage: sudo bash uninstall.sh
#
# This never signals a process directly — `systemctl stop` lets systemd tear
# down its own cgroups, which is the safe way to stop something attached to
# a live GNOME session.
#
# Two machine-wide settings are deliberately NOT reverted; see the notes at
# the end of this script for what is left behind and why.

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root. Use: sudo bash uninstall.sh"; exit 1; }

# ── [1/6] ────────────────────────────────────────────────────────────────────
# The watcher goes FIRST, and this ordering is load-bearing. Its entire job is
# `systemctl restart x11vnc` whenever the active session stops matching what
# x11vnc is attached to. Stop x11vnc while the watcher is still running and it
# will happily start it again a few seconds later, mid-uninstall, leaving an
# orphaned x11vnc holding port 5900 after this script reports success.
echo "=== [1/6] Stopping the v4 switch watcher (before x11vnc, on purpose) ==="
systemctl stop x11vnc-watcher 2>/dev/null || true
systemctl disable x11vnc-watcher 2>/dev/null || true
rm -f /etc/systemd/system/x11vnc-watcher.service
rm -f /usr/local/bin/x11vnc-watch.sh

echo "=== [2/6] Stopping and removing x11vnc + websockify ==="
systemctl stop x11vnc websockify 2>/dev/null || true
systemctl disable x11vnc websockify 2>/dev/null || true

rm -f /etc/systemd/system/x11vnc.service
rm -f /etc/systemd/system/websockify.service
rm -f /usr/local/bin/x11vnc-start.sh
systemctl daemon-reload

echo "=== [3/6] Removing legacy per-user units ==="
# Per-user units from older versions of the installer, which wrote into the
# detected desktop user's home — including gdm's own home (/var/lib/gdm3) if
# it ran before the UID >= 1000 filter existed. These survive a package purge
# and will fight a future install for ports 5900/6080.
while IFS=: read -r u _ uid _ _ home _; do
    [[ -n "$home" && -d "$home" ]] || continue
    unit_dir="$home/.config/systemd/user"
    [[ -f "$unit_dir/x11vnc.service" || -f "$unit_dir/websockify.service" ]] || continue
    echo "  Removing legacy per-user units for $u ($unit_dir)"
    if [[ -d "/run/user/$uid" ]]; then
        sudo -u "$u" XDG_RUNTIME_DIR="/run/user/$uid" \
            systemctl --user stop x11vnc websockify 2>/dev/null || true
        sudo -u "$u" XDG_RUNTIME_DIR="/run/user/$uid" \
            systemctl --user disable x11vnc websockify 2>/dev/null || true
    fi
    rm -f "$unit_dir/x11vnc.service" "$unit_dir/websockify.service"
    # Linger was only ever enabled to keep those units alive.
    loginctl disable-linger "$u" 2>/dev/null || true
done < <(getent passwd)

echo "=== [4/6] Stopping and removing Teleport ==="
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

echo "=== [5/6] Purging packages ==="
apt-get purge -y teleport 2>/dev/null || true
apt-get purge -y x11vnc novnc python3-websockify 2>/dev/null || true
# psmisc is deliberately NOT purged. The installer pulls it in for `fuser`,
# but it is a general-purpose utility package (fuser, killall, pstree) that
# plenty of other things and people expect to be present. Removing it would
# be a bigger side effect than leaving it.
apt-get autoremove -y 2>/dev/null || true

echo "=== [6/6] Reverting the per-user Xorg session default ==="
# The installer pinned $DESKTOP_USER to an Xorg session via AccountsService so
# x11vnc could capture the desktop. Strip that back out — but only lines whose
# value is one of the Xorg sessions we actually set, so a deliberate choice
# made by an admin for some other session type is left alone. Removing the key
# entirely (rather than writing some other value) returns the account to the
# system default, which is the correct "as if never installed" state.
if [[ -d /var/lib/AccountsService/users ]]; then
    for acct in /var/lib/AccountsService/users/*; do
        [[ -f "$acct" ]] || continue
        if grep -qE '^X?Session=(ubuntu-xorg|gnome-xorg)$' "$acct"; then
            echo "  Clearing forced Xorg session in $acct"
            sed -i -E '/^X?Session=(ubuntu-xorg|gnome-xorg)$/d' "$acct"
        fi
    done
fi

echo ""
echo "=============================="
echo "VS uninstall complete."
echo ""
echo "LEFT IN PLACE ON PURPOSE:"
echo ""
echo "  1. Wayland is still disabled at GDM."
echo "     The installer set WaylandEnable=false in /etc/gdm3/custom.conf so"
echo "     x11vnc could capture the desktop. It is NOT reverted here: there is"
echo "     no way to tell that line apart from one an admin set themselves, and"
echo "     silently switching a machine's display server back to Wayland during"
echo "     an uninstall is a larger surprise than leaving it on Xorg, which"
echo "     harms nothing. To revert by hand:"
echo "       sudo sed -i 's/^WaylandEnable=false/#WaylandEnable=false/' /etc/gdm3/custom.conf"
echo "     (takes effect next reboot)"
echo ""
echo "  2. psmisc is still installed — general-purpose utility package."
echo ""
echo "Run setup-v4.sh to reinstall."
echo "=============================="
