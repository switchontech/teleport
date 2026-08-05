#!/bin/bash
# Static, self-contained VS installer: Teleport (SSH + VNC App) on Ubuntu/GNOME.
# Proxy/token/CA-pin are baked in below — copy this one file to any VS machine
# and run it, nothing else needed.
#
# Usage: sudo bash setup.sh   (VS identity is always this machine's hostname)
#
# If the server's PUBLIC_ADDR or VS_JOIN_TOKEN in .env ever changes, re-run
# on the server: bash bake-installer.sh   — it rewrites these three values
# below in place.

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root. Use: sudo bash setup.sh ..."; exit 1; }

PROXY="172.30.196.160.nip.io:3080"
TOKEN="vs-join-token-switchon"
CA_PIN="sha256:d34246f0cde514c311315c5c3e234ef96d3592d9b9c499fc60c45010242dc7cf"

VS_NAME="$(hostname)"

TELEPORT_VERSION="18.10.0"
VNC_PORT="5900"
NOVNC_PORT="6080"

PROXY_HOST="${PROXY%%:*}"

# Whoever currently holds the active graphical seat — not whoever ran sudo.
# This is the desktop that gets shared, regardless of which account installs it.
DESKTOP_USER=""
for session in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
    session_state=$(loginctl show-session "$session" -p State --value 2>/dev/null || true)
    session_type=$(loginctl show-session "$session" -p Type --value 2>/dev/null || true)
    if [[ "$session_state" == "active" && ( "$session_type" == "x11" || "$session_type" == "wayland" ) ]]; then
        session_user=$(loginctl show-session "$session" -p Name --value 2>/dev/null || true)
        # Skip service/greeter accounts (e.g. gdm's own login-screen session,
        # which can also report as an "active" x11/wayland session) — only
        # accept real human logins (UID >= 1000, standard Debian/Ubuntu convention).
        session_uid=$(id -u "$session_user" 2>/dev/null || echo -1)
        if [[ "$session_uid" -lt 1000 ]]; then
            continue
        fi
        DESKTOP_USER="$session_user"
        SESSION_TYPE_DETECTED="$session_type"
        break
    fi
done
if [[ -z "$DESKTOP_USER" ]]; then
    DESKTOP_USER="${SUDO_USER:-$USER}"
    echo "WARNING: no active graphical session found via loginctl. Falling back to: $DESKTOP_USER"
else
    echo "Active desktop session found: user=$DESKTOP_USER type=$SESSION_TYPE_DETECTED"
    if [[ "$SESSION_TYPE_DETECTED" == "wayland" ]]; then
        echo "WARNING: session is Wayland, not Xorg. x11vnc needs a real X11 session —"
        echo "         it will likely only capture XWayland windows, not the full desktop."
        echo "         Log the desktop user into an 'Ubuntu on Xorg' session instead for full-screen sharing."
    fi
fi
DESKTOP_HOME=$(eval echo "~$DESKTOP_USER")

echo "=== [1/6] Installing Teleport $TELEPORT_VERSION ==="
curl -fsSL https://goteleport.com/static/install.sh | bash -s "$TELEPORT_VERSION"

echo "=== [2/6] Installing x11vnc + noVNC + websockify ==="
apt-get update -qq

# Pin exact package versions per supported Ubuntu release — apt package
# versions differ across releases (confirmed: novnc 1:1.0.0-5 on 22.04 vs
# 1:1.3.0-2 on 24.04), so an unpinned install silently drifts per-machine.
# Fail loudly on any release we haven't pinned versions for, rather than
# installing whatever apt happens to resolve.
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
        echo "       Supported: 22.04, 24.04. Add pinned versions here if you need to support it."
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
    echo "         (Needs a kernel built with CONFIG_DEBUG_INFO_BTF=y, e.g. stock"
    echo "         Ubuntu 20.04+ kernels.)"
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

echo "=== [5/6] Setting up x11vnc + websockify ==="

loginctl enable-linger "$DESKTOP_USER"
sleep 1

USER_ID=$(id -u "$DESKTOP_USER")
export XDG_RUNTIME_DIR="/run/user/${USER_ID}"

# Kill gnome-remote-desktop if present (conflicts on port 5900)
sudo -u "$DESKTOP_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user stop gnome-remote-desktop 2>/dev/null || true
sudo -u "$DESKTOP_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user disable gnome-remote-desktop 2>/dev/null || true

mkdir -p "$DESKTOP_HOME/.config/systemd/user"

# Wrapper: auto-detects display and xauth at runtime
cat > /usr/local/bin/x11vnc-start.sh <<'WRAPPER'
#!/bin/bash
for display in :0 :1 :2; do
    if DISPLAY=$display xdpyinfo >/dev/null 2>&1; then
        X_DISPLAY=$display
        break
    fi
done

if [[ -z "$X_DISPLAY" ]]; then
    echo "No X display found, retrying in 5s..."
    sleep 5
    exec "$0"
fi

XAUTH=""
for f in /run/user/*/gdm/Xauthority /run/user/*/.mutter-Xwaylandauth* /home/*/.Xauthority; do
    [ -r "$f" ] && XAUTH="$f" && break
done

echo "Starting x11vnc on display $X_DISPLAY with auth $XAUTH"
exec /usr/bin/x11vnc \
    -display "$X_DISPLAY" \
    -auth "$XAUTH" \
    -nopw -forever -shared \
    -rfbport 5900 -localhost
WRAPPER
chmod +x /usr/local/bin/x11vnc-start.sh

cat > "$DESKTOP_HOME/.config/systemd/user/x11vnc.service" <<EOF
[Unit]
Description=x11vnc — share real display
After=graphical-session.target

[Service]
ExecStart=/usr/local/bin/x11vnc-start.sh
Restart=always
RestartSec=5

[Install]
WantedBy=graphical-session.target
EOF

# websockify binary: prefer python3-websockify, fall back to novnc bundled
WEBSOCKIFY_BIN=$(command -v websockify || command -v /usr/share/novnc/utils/websockify/run || echo websockify)

cat > "$DESKTOP_HOME/.config/systemd/user/websockify.service" <<EOF
[Unit]
Description=websockify noVNC proxy

[Service]
ExecStart=${WEBSOCKIFY_BIN} --web /usr/share/novnc ${NOVNC_PORT} localhost:${VNC_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

chown -R "$DESKTOP_USER:$DESKTOP_USER" "$DESKTOP_HOME/.config"

# Force-clear the VNC/noVNC ports first — a stray process from a prior
# manual run or previous setup.sh attempt (possibly owned by root or another
# user) will otherwise block our managed instances from ever binding,
# causing an endless restart loop. We're root here so we can kill either
# regardless of owner; the systemd units themselves (running as
# $DESKTOP_USER) couldn't.
fuser -k "${VNC_PORT}/tcp" 2>/dev/null || true
fuser -k "${NOVNC_PORT}/tcp" 2>/dev/null || true
sleep 1

sudo -u "$DESKTOP_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user daemon-reload
sudo -u "$DESKTOP_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user enable x11vnc websockify
sudo -u "$DESKTOP_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user restart x11vnc websockify

echo "=== Starting Teleport ==="
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
echo "=============================="
