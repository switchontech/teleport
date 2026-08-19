#!/bin/bash
# Static, self-contained VS installer: Teleport (SSH + VNC App) on Ubuntu/GNOME.
# Proxy/token/CA-pin are baked in below — copy this one file to any VS machine
# and run it, nothing else needed.
#
# Usage: sudo bash setup.sh   (VS identity is always this machine's hostname)
#
# If the server's PUBLIC_ADDR or VS_JOIN_TOKEN in .env ever changes, re-run
# on the server: bash bake.sh   — it rewrites these three values below in
# place.
#
# Design note: this script never sends a signal to any process. Process
# lifecycle is entirely systemd's job — the x11vnc wrapper exits when it
# needs to change displays and systemd restarts it. Earlier versions used
# pkill/kill/fuser -k and every one of them caused collateral damage on a
# live GNOME session.

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root. Use: sudo bash setup.sh"; exit 1; }

PROXY="172.30.196.160.nip.io:3080"
TOKEN="vs-join-token-switchon"
CA_PIN="sha256:d34246f0cde514c311315c5c3e234ef96d3592d9b9c499fc60c45010242dc7cf"

VS_NAME="$(hostname)"

TELEPORT_VERSION="18.10.0"
VNC_PORT="5900"
NOVNC_PORT="6080"

PROXY_HOST="${PROXY%%:*}"

# ── Which desktop user to record in the vs-user label ────────────────────────
# Whoever currently holds the active graphical seat — not whoever ran sudo.
# Note: "active" and "online" are different logind states. active = the
# session currently on the seat (on screen); online = logged in but
# backgrounded. With two users logged in simultaneously BOTH are listed and
# only one is active, so keying on "online" would match either at random.
# The -n "$session_seat" test additionally rejects SSH sessions, which have
# no seat but can still report State=active.
DESKTOP_USER=""
SESSION_TYPE_DETECTED=""
for session in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
    session_state=$(loginctl show-session "$session" -p State --value 2>/dev/null || true)
    session_type=$(loginctl show-session "$session" -p Type --value 2>/dev/null || true)
    session_seat=$(loginctl show-session "$session" -p Seat --value 2>/dev/null || true)
    if [[ "$session_state" == "active" && ( "$session_type" == "x11" || "$session_type" == "wayland" ) && -n "$session_seat" ]]; then
        session_user=$(loginctl show-session "$session" -p Name --value 2>/dev/null || true)
        # Skip service/greeter accounts (gdm's own login-screen session also
        # reports as an active x11 session) — real human logins are UID >= 1000.
        session_uid=$(id -u "$session_user" 2>/dev/null || echo -1)
        [[ "$session_uid" -lt 1000 ]] && continue
        DESKTOP_USER="$session_user"
        SESSION_TYPE_DETECTED="$session_type"
        break
    fi
done
if [[ -z "$DESKTOP_USER" ]]; then
    DESKTOP_USER="${SUDO_USER:-$USER}"
    echo "WARNING: no active graphical session found. Falling back to: $DESKTOP_USER"
else
    echo "Active desktop session: user=$DESKTOP_USER type=$SESSION_TYPE_DETECTED"
    if [[ "$SESSION_TYPE_DETECTED" == "wayland" ]]; then
        echo "WARNING: session is Wayland, not Xorg. x11vnc needs a real X11 session —"
        echo "         it will only capture XWayland windows, not the full desktop."
    fi
fi

# ── Force Xorg for $DESKTOP_USER ─────────────────────────────────────────────
# Applies unconditionally, not just when Wayland was detected above: even if
# no session was active at all (freshly rebooted/idle-locked VS), the next
# time $DESKTOP_USER does log in, it should be Xorg so x11vnc can capture
# the full desktop instead of just XWayland windows.
#
# Config only, no gdm restart here: if $DESKTOP_USER's session IS currently
# active (the Wayland-warning case above), restarting gdm now would kick
# them off mid-use — the exact collateral damage this script avoids
# everywhere else. Takes effect on the next natural login/reboot instead.
XORG_SESSION=""
for candidate in ubuntu-xorg gnome-xorg; do
    [[ -f "/usr/share/xsessions/${candidate}.desktop" ]] && { XORG_SESSION="$candidate"; break; }
done
if [[ -n "$XORG_SESSION" ]]; then
    ACCT_DIR="/var/lib/AccountsService/users"
    ACCT_FILE="${ACCT_DIR}/${DESKTOP_USER}"
    mkdir -p "$ACCT_DIR"
    if [[ -f "$ACCT_FILE" ]]; then
        grep -q '^Session=' "$ACCT_FILE" \
            && sed -i "s/^Session=.*/Session=${XORG_SESSION}/" "$ACCT_FILE" \
            || sed -i "/^\[User\]/a Session=${XORG_SESSION}" "$ACCT_FILE"
        grep -q '^XSession=' "$ACCT_FILE" \
            && sed -i "s/^XSession=.*/XSession=${XORG_SESSION}/" "$ACCT_FILE" \
            || sed -i "/^\[User\]/a XSession=${XORG_SESSION}" "$ACCT_FILE"
    else
        cat > "$ACCT_FILE" <<ACCTEOF
[User]
Session=${XORG_SESSION}
XSession=${XORG_SESSION}
SystemAccount=false
ACCTEOF
    fi
    echo "Default session for $DESKTOP_USER set to '${XORG_SESSION}' (takes effect next login)."
else
    echo "WARNING: no Xorg session found (checked ubuntu-xorg, gnome-xorg) — cannot force Xorg default."
fi

# ── Disable Wayland at GDM, for every account on the machine ─────────────────
# The AccountsService block above only covers $DESKTOP_USER — whoever happened
# to be at the seat when this installer ran. Any other account that logs in
# later gets Ubuntu's default, which is Wayland, and a Wayland session breaks
# the screen share SILENTLY rather than loudly: `who` reports a tty instead of
# a ":N" display for Wayland sessions, so the x11vnc wrapper never finds a
# display to attach to and just retries forever with no error. (Even if it did
# attach, x11vnc only captures XWayland windows, not the desktop.)
#
# Setting it at the display manager covers every account — including ones
# created after this installer ran — instead of one account per install.
#
# No gdm restart here: that would kill the session of whoever is logged in
# right now. Takes effect at the next login/reboot, same as the per-user
# default above.
GDM_CONF=""
for candidate in /etc/gdm3/custom.conf /etc/gdm/custom.conf; do
    [[ -f "$candidate" ]] && { GDM_CONF="$candidate"; break; }
done
if [[ -n "$GDM_CONF" ]]; then
    if grep -qE '^[[:space:]]*WaylandEnable[[:space:]]*=' "$GDM_CONF"; then
        # An active setting already exists — force it to false whatever it said.
        sed -i -E 's/^[[:space:]]*WaylandEnable[[:space:]]*=.*/WaylandEnable=false/' "$GDM_CONF"
    elif grep -qE '^[[:space:]]*#[[:space:]]*WaylandEnable[[:space:]]*=' "$GDM_CONF"; then
        # Ubuntu ships it commented out — uncomment in place, inside [daemon].
        sed -i -E 's/^[[:space:]]*#[[:space:]]*WaylandEnable[[:space:]]*=.*/WaylandEnable=false/' "$GDM_CONF"
    elif grep -qE '^[[:space:]]*\[daemon\]' "$GDM_CONF"; then
        sed -i '/^[[:space:]]*\[daemon\]/a WaylandEnable=false' "$GDM_CONF"
    else
        printf '\n[daemon]\nWaylandEnable=false\n' >> "$GDM_CONF"
    fi
    if grep -qE '^WaylandEnable=false' "$GDM_CONF"; then
        echo "Wayland disabled for all users in $GDM_CONF (takes effect next login/reboot)."
    else
        echo "ERROR: failed to set WaylandEnable=false in $GDM_CONF — check it by hand."
        exit 1
    fi
else
    echo "WARNING: no GDM config found (checked /etc/gdm3/custom.conf, /etc/gdm/custom.conf)."
    echo "         Cannot force Xorg machine-wide. If any user logs in under Wayland,"
    echo "         the screen share will silently never attach for that user."
fi

echo "=== [1/6] Installing Teleport $TELEPORT_VERSION ==="
curl -fsSL https://goteleport.com/static/install.sh | bash -s "$TELEPORT_VERSION"

echo "=== [2/6] Installing x11vnc + noVNC + websockify ==="
apt-get update -qq

# Pin exact package versions per supported Ubuntu release — apt package
# versions differ across releases (confirmed: novnc 1:1.0.0-5 on 22.04 vs
# 1:1.3.0-2 on 24.04), so an unpinned install silently drifts per-machine.
# Fail loudly on any release we haven't pinned versions for.
. /etc/os-release
case "$VERSION_ID" in
    22.04)
        X11VNC_VER="0.9.16-8"
        NOVNC_VER="1:1.0.0-5"
        WEBSOCKIFY_VER="0.10.0+dfsg1-2build1"
        ;;
    24.04)
        X11VNC_VER="0.9.16-10"
        NOVNC_VER="1:1.3.0-2"
        WEBSOCKIFY_VER="0.10.0+dfsg1-5build2"
        ;;
    *)
        echo "ERROR: Ubuntu $VERSION_ID is not a supported/pinned release for this installer."
        echo "       Supported: 22.04, 24.04. Add pinned versions here if you need it."
        exit 1
        ;;
esac

apt-get install -y \
    x11vnc="$X11VNC_VER" \
    novnc="$NOVNC_VER" \
    python3-websockify="$WEBSOCKIFY_VER" \
    psmisc

echo "=== [3/6] Checking BPF enhanced session recording support ==="
ENHANCED_RECORDING_ENABLED="true"
if [[ ! -e /sys/kernel/btf/vmlinux ]]; then
    echo "WARNING: /sys/kernel/btf/vmlinux not found — kernel lacks BTF, command"
    echo "         recording (enhanced_recording) will fail to start. Disabling it."
    ENHANCED_RECORDING_ENABLED="false"
fi

echo "=== [4/6] Writing Teleport config ==="
cat > /etc/teleport.yaml <<EOF
version: v3
teleport:
  data_dir: /var/lib/teleport
  join_params:
    token_name: "${TOKEN}"
    method: token
  ca_pin: "${CA_PIN}"
  proxy_server: "${PROXY}"
auth_service:
  enabled: false
proxy_service:
  enabled: false
ssh_service:
  enabled: true
  enhanced_recording:
    enabled: ${ENHANCED_RECORDING_ENABLED}
  labels:
    vs-id: "${VS_NAME}"
    vs-user: "${DESKTOP_USER}"
    env: plant
app_service:
  enabled: true
  apps:
    - name: "${VS_NAME}"
      uri: "http://localhost:${NOVNC_PORT}/vnc_auto.html?resize=scale"
      public_addr: "${VS_NAME}.${PROXY_HOST}"
      labels:
        vs-id: "${VS_NAME}"
        env: plant
EOF

echo "=== [5/6] Setting up x11vnc + websockify (system-level, run as root) ==="

# Run as root, not as a specific desktop user. Whoever is at the desktop
# changes over a VS's lifetime, and a `systemctl --user` service is pinned to
# one account forever — it cannot read another user's ~/.Xauthority (mode
# 600), so a user switch left the share attached to a dead session. Root can
# read any user's Xauthority, so one service follows whoever is actually
# logged in.
#
# Deliberately NOT touching gnome-remote-desktop. Masking its unit broke
# GDM's display-switch handling outright; pkill-ing it by name was no safer.
# If it holds port 5900 the check below reports it rather than killing it.

# Clear out per-user units from older versions of this installer, which
# installed into the detected desktop user's home — including gdm's own home
# (/var/lib/gdm3) if it ran before the UID >= 1000 filter existed. Left in
# place they compete with the system-level units for ports 5900/6080 and can
# sit in a permanent systemd restart loop. Removing files only, no signals —
# `systemctl --user disable` without --now leaves running processes alone,
# and they go away on next logout/reboot.
while IFS=: read -r u _ uid _ _ home _; do
    [[ -n "$home" && -d "$home" ]] || continue
    unit_dir="$home/.config/systemd/user"
    [[ -f "$unit_dir/x11vnc.service" || -f "$unit_dir/websockify.service" ]] || continue
    echo "  Removing legacy per-user units for $u ($unit_dir)"
    if [[ -d "/run/user/$uid" ]]; then
        sudo -u "$u" XDG_RUNTIME_DIR="/run/user/$uid" \
            systemctl --user disable x11vnc websockify 2>/dev/null || true
    fi
    rm -f "$unit_dir/x11vnc.service" "$unit_dir/websockify.service"
    # Linger was only ever enabled to keep those units alive.
    loginctl disable-linger "$u" 2>/dev/null || true
done < <(getent passwd)

# ── The x11vnc wrapper ───────────────────────────────────────────────────────
cat > /usr/local/bin/x11vnc-start.sh <<'WRAPPER'
#!/bin/bash
# Attaches x11vnc to whichever graphical session is currently ACTIVE on the
# seat, and exits when that stops being true so systemd can restart it
# against the new one.
#
# This script never signals a process. When the active display changes it
# just exits; systemd tears down the rest of the cgroup (x11vnc included)
# and Restart=always brings up a clean instance. That is deliberate — every
# earlier version that issued kill/pkill itself caused collateral damage on
# a live GNOME session.

POLL_SECONDS=5

# Print "<user> <display>" for the session currently on the seat, or nothing.
#
# Two lookups, because neither alone is reliable here:
#   - logind knows which session is *active* (on screen) vs merely *online*
#     (logged in, backgrounded). Fast user switching leaves the previous
#     user's X server alive, so "an X server that answers on :0/:1/:2" is
#     not the same question as "the one on screen".
#   - logind's own Display property comes back empty for X11 sessions on
#     some GDM versions, so the display number itself comes from `who`
#     (utmp), which reports it as the TTY field, e.g. "prod :1".
active_session() {
    local session state type seat user uid display
    for session in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
        state=$(loginctl show-session "$session" -p State --value 2>/dev/null || true)
        type=$(loginctl show-session "$session" -p Type --value 2>/dev/null || true)
        seat=$(loginctl show-session "$session" -p Seat --value 2>/dev/null || true)
        [[ "$state" == "active" ]] || continue
        [[ "$type" == "x11" || "$type" == "wayland" ]] || continue
        [[ -n "$seat" ]] || continue          # rejects SSH sessions
        user=$(loginctl show-session "$session" -p Name --value 2>/dev/null || true)
        uid=$(id -u "$user" 2>/dev/null || echo -1)
        [[ "$uid" -ge 1000 ]] || continue     # rejects gdm's greeter session
        display=$(who | awk -v u="$user" '$1==u && $2 ~ /^:[0-9]+$/ {print $2; exit}')
        [[ -n "$display" ]] || continue
        echo "$user $display"
        return 0
    done
    return 1
}

# Xauthority for a given user, checked in the order GDM actually uses.
find_xauth() {
    local uid="$1" home="$2" f
    for f in "/run/user/${uid}/gdm/Xauthority" /run/user/${uid}/.mutter-Xwaylandauth* "${home}/.Xauthority"; do
        [[ -r "$f" ]] && { echo "$f"; return 0; }
    done
    return 1
}

# Wait for a usable active session.
while true; do
    if read -r USER_NAME X_DISPLAY < <(active_session); then
        USER_UID=$(id -u "$USER_NAME")
        USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
        if XAUTH=$(find_xauth "$USER_UID" "$USER_HOME") \
           && XAUTHORITY="$XAUTH" DISPLAY="$X_DISPLAY" xdpyinfo >/dev/null 2>&1; then
            break
        fi
    fi
    echo "No usable active graphical session yet, retrying in ${POLL_SECONDS}s..."
    sleep "$POLL_SECONDS"
done

if ss -ltn "sport = :5900" 2>/dev/null | grep -q LISTEN; then
    echo "WARNING: something is already listening on port 5900 (gnome-remote-desktop?)."
    echo "         x11vnc will fail to bind. Not killing it — stop it yourself if unwanted."
fi

echo "Starting x11vnc for $USER_NAME on display $X_DISPLAY (auth: $XAUTH)"

# Flag rationale:
#   -noshm    MIT-SHM is gated on matching UID, not just a valid Xauth cookie.
#             Running as root against another user's display gets BadAccess on
#             X_ShmAttach. Falls back to plain XGetImage polling — slower, but
#             SHM cannot work cross-UID at all.
#   -noscr    Disables scroll detection, which taps the X server's entire
#             event stream via the RECORD extension.
#   -nowf     Disables wireframe window moves.
#   -nowcr    Disables copyrect-after-move.
# (Dropped -nograbs: not a recognized option on the pinned x11vnc build —
# it exits immediately with "unrecognized option(s)", which looked from the
# outside like x11vnc silently dying every restart cycle.)
/usr/bin/x11vnc \
    -display "$X_DISPLAY" \
    -auth "$XAUTH" \
    -noshm -noscr -nowf -nowcr \
    -nopw -forever -shared \
    -rfbport 5900 -localhost &
VNC_PID=$!

# Watch for the active session changing. On any change, exit — systemd stops
# the rest of the cgroup and restarts us clean. `ps` only reads /proc, it
# does not signal anything.
while true; do
    sleep "$POLL_SECONDS"

    if [[ "$(ps -p "$VNC_PID" -o comm= 2>/dev/null)" != "x11vnc" ]]; then
        echo "x11vnc is gone — exiting so systemd restarts cleanly."
        exit 0
    fi

    if read -r NOW_USER NOW_DISPLAY < <(active_session); then
        if [[ "$NOW_DISPLAY" != "$X_DISPLAY" ]]; then
            echo "Active session moved to $NOW_USER on $NOW_DISPLAY — exiting so systemd reattaches."
            exit 0
        fi
    else
        echo "No active graphical session — exiting so systemd reattaches when one returns."
        exit 0
    fi
done
WRAPPER
chmod +x /usr/local/bin/x11vnc-start.sh

# After=network.target, NOT graphical.target: graphical.target itself requires
# multi-user.target, so ordering after it while being WantedBy=multi-user.target
# is a dependency cycle. systemd breaks such cycles by deleting a job, which
# silently left this service dead after boot.
cat > /etc/systemd/system/x11vnc.service <<EOF
[Unit]
Description=x11vnc — shares whichever desktop session is currently active
After=network.target

[Service]
ExecStart=/usr/local/bin/x11vnc-start.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# websockify binary: prefer the python3-websockify package, fall back to the
# copy bundled with noVNC.
WEBSOCKIFY_BIN=$(command -v websockify || command -v /usr/share/novnc/utils/websockify/run || echo websockify)

cat > /etc/systemd/system/websockify.service <<EOF
[Unit]
Description=websockify noVNC proxy
After=network.target

[Service]
ExecStart=${WEBSOCKIFY_BIN} --web /usr/share/novnc ${NOVNC_PORT} localhost:${VNC_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Force-clear the VNC/noVNC ports first — a stray process from a prior
# manual run, a previous setup.sh attempt, or an old per-user instance from
# before this script ran system-level services will otherwise block these
# from ever binding, causing an endless restart loop.
fuser -k "${VNC_PORT}/tcp" 2>/dev/null || true
fuser -k "${NOVNC_PORT}/tcp" 2>/dev/null || true
sleep 1

systemctl daemon-reload
systemctl enable x11vnc websockify
systemctl restart x11vnc websockify

echo "=== [6/6] Starting Teleport ==="
systemctl enable teleport

mkdir -p /etc/systemd/system/teleport.service.d/
cat > /etc/systemd/system/teleport.service.d/insecure.conf <<'DROPIN'
[Service]
ExecStart=
ExecStart=/usr/local/bin/teleport start --config /etc/teleport.yaml --pid-file=/run/teleport.pid --insecure
DROPIN
systemctl daemon-reload

systemctl restart teleport
sleep 4
systemctl status teleport --no-pager | head -8

echo ""
echo "=============================="
echo "VS setup complete: ${VS_NAME}"
echo "SSH:     Teleport → Servers → ${VS_NAME}"
echo "Desktop: Teleport → Applications → ${VS_NAME}"
echo ""
echo "Watch the screen-share follow user switches with:"
echo "  journalctl -u x11vnc -f"
echo "=============================="
