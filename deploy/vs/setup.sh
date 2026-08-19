#!/bin/bash
# Static, self-contained VS installer: Teleport (SSH + VNC App) on Ubuntu/GNOME.
# Proxy/token/CA-pin are baked in below — copy this one file to any VS machine
# and run it, nothing else needed.
#
# Usage: sudo bash setup.sh   (VS identity = the first linux user)
#
# If the server's PUBLIC_ADDR or VS_JOIN_TOKEN in .env changes, re-run on the
# server: bash bake.sh — it rewrites the three values below in place.

# The screen share follows a fast user switch, but only ~6s AFTER the new
# session settles.
#


set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root. Use: sudo bash setup.sh"; exit 1; }

PROXY="172.30.196.160.nip.io:3080"
TOKEN="vs-join-token-switchon"
CA_PIN="sha256:d34246f0cde514c311315c5c3e234ef96d3592d9b9c499fc60c45010242dc7cf"

TELEPORT_VERSION="18.10.0"
VNC_PORT="5900"
NOVNC_PORT="6080"

PROXY_HOST="${PROXY%%:*}"

# ── Release gate ─────────────────────────────────────────────────────────────
# Versions pinned per release: apt resolves different ones per release and
# x11vnc's accepted flags differ between builds.
# Runs first, before anything is modified — it used to sit after the GDM and
# Teleport changes, so an unsupported release left the machine half-configured.
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
        echo "ERROR: Ubuntu $VERSION_ID is not a supported/pinned release."
        echo "       Supported: 22.04, 24.04. Nothing has been modified."
        exit 1
        ;;
esac

# ── VS identity = first linux user (lowest UID >= 1000) ──────────────────────
# Feeds the node name, the app public_addr, and the vs-user label.
# Read from /etc/passwd so it is identical on every run: it used to come from
# whoever held the desktop, so an update from a `customer` session renamed the
# node and granted `customer` cluster-wide SSH via ssh-access-watcher.
# The screen share does not use this — it re-derives the live session at runtime.
FIRST_USER=$(getent passwd \
    | awk -F: '$3 >= 1000 && $3 < 65534 { print $3":"$1 }' \
    | sort -n | head -1 | cut -d: -f2)

if [[ -z "$FIRST_USER" ]]; then
    echo "ERROR: no human user account found (UID >= 1000). Cannot derive VS identity."
    echo "       Create the primary user account before running this installer."
    exit 1
fi

VS_NAME="$FIRST_USER"
echo "VS identity: ${VS_NAME} (first linux user, UID $(id -u "$FIRST_USER"))"

# ── Session type on the seat (Xorg vs Wayland) ───────────────────────────────
# Only used for the REBOOT REQUIRED warning at the end. No username is recorded.
# state==active, not "online": both are listed when two users are logged in and
# only one is on screen. -n "$session_seat" rejects SSH sessions, which have no
# seat but can still report active.
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
        SESSION_TYPE_DETECTED="$session_type"
        break
    fi
done

# ── Force Xorg for every human account ───────────────────────────────────────
# x11vnc cannot capture a Wayland desktop, and the next person to log in is
# unknown at install time — so pin every account, not just the current one.
# Config only, no gdm restart: that would kick off whoever is logged in now.
XORG_SESSION=""
for candidate in ubuntu-xorg gnome-xorg; do
    [[ -f "/usr/share/xsessions/${candidate}.desktop" ]] && { XORG_SESSION="$candidate"; break; }
done
if [[ -n "$XORG_SESSION" ]]; then
    ACCT_DIR="/var/lib/AccountsService/users"
    mkdir -p "$ACCT_DIR"
    while IFS=: read -r acct_user _ acct_uid _ _ _ _; do
        [[ "$acct_uid" -ge 1000 && "$acct_uid" -lt 65534 ]] || continue
        ACCT_FILE="${ACCT_DIR}/${acct_user}"
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
        echo "  Default session for $acct_user set to '${XORG_SESSION}'."
    done < <(getent passwd)
    echo "Xorg pinned for all human accounts (takes effect next login)."
else
    echo "WARNING: no Xorg session found (checked ubuntu-xorg, gnome-xorg)."
    echo "         Cannot force an Xorg default, and Wayland will NOT be disabled"
    echo "         below — disabling it with no X11 session to fall back to would"
    echo "         leave GDM nothing to launch and lock everyone out of the desktop."
fi

# ── Disable Wayland at GDM, for every account on the machine ─────────────────
# Belt and braces alongside the AccountsService pin above: that sets a per-user
# default, this removes Wayland as an option at the display manager, including
# for accounts created after this installer ran. A Wayland session breaks the
# screen share SILENTLY rather than loudly — `who` reports a tty instead of a
# ":N" display, so the x11vnc wrapper never finds a display to attach to and
# just retries forever with no error. (Even if it did attach, x11vnc only
# captures XWayland windows, not the desktop.)
#
# It matters because the share follows whoever logs in next, and that account
# is not known at install time.
#
# No gdm restart here: that would kill the session of whoever is logged in
# right now. Takes effect at the next login/reboot, same as the per-user
# default above.
#
# GATED on an Xorg session actually existing. Disabling Wayland on a machine
# that has no X11 session installed leaves GDM with nothing to launch — the
# login screen breaks and every fix needs physical access to the machine.
# Stock 22.04/24.04 always ship ubuntu-xorg.desktop, so this is insurance
# rather than a live bug — but these are custom remastered images, and
# remasters strip packages.
GDM_CONF=""
if [[ -n "$XORG_SESSION" ]]; then
    for candidate in /etc/gdm3/custom.conf /etc/gdm/custom.conf; do
        [[ -f "$candidate" ]] && { GDM_CONF="$candidate"; break; }
    done
fi
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
elif [[ -z "$XORG_SESSION" ]]; then
    echo "SKIPPED disabling Wayland at GDM: no Xorg session exists to fall back to."
    echo "        Install an Xorg session (gnome-session-xsession) and re-run, or"
    echo "        the screen share will not work on this machine."
else
    echo "WARNING: no GDM config found (checked /etc/gdm3/custom.conf, /etc/gdm/custom.conf)."
    echo "         Cannot force Xorg machine-wide. If any user logs in under Wayland,"
    echo "         the screen share will silently never attach for that user."
fi

echo "=== [1/6] Installing Teleport $TELEPORT_VERSION ==="
curl -fsSL https://goteleport.com/static/install.sh | bash -s "$TELEPORT_VERSION"

echo "=== [2/6] Installing x11vnc + noVNC + websockify ==="
# `|| true`: a single unreachable third-party repo would otherwise abort the
# whole install under `set -e`. If the index really is unusable the pinned
# installs below fail loudly anyway, so nothing is silently skipped.
apt-get update -qq || echo "WARNING: apt-get update failed — continuing with the cached index."

# x11-utils supplies xdpyinfo. x11vnc only *Recommends* it, so an image built
# with --no-install-recommends (common for remasters) will not have it — and
# both x11vnc-start.sh and x11vnc-watch.sh gate every attach on xdpyinfo. Its
# absence produces the worst failure mode available: the share never attaches,
# with no error, retrying forever. Install it explicitly.
EXTRA_PKGS=(psmisc x11-utils)

# Try the pinned versions first (see the release gate at the top for why they
# are pinned). If the archive has superseded one — a security update lands and
# the old version is gone — install unpinned rather than aborting the whole
# provisioning run. The thing pinning actually protects against is a flag/
# behaviour change, and that is verified directly further down by starting
# x11vnc with our real flag set, which catches it on any version.
if ! apt-get install -y \
        x11vnc="$X11VNC_VER" \
        novnc="$NOVNC_VER" \
        python3-websockify="$WEBSOCKIFY_VER" \
        "${EXTRA_PKGS[@]}"; then
    echo "WARNING: pinned package versions unavailable for Ubuntu ${VERSION_ID}."
    echo "         Wanted x11vnc=$X11VNC_VER novnc=$NOVNC_VER websockify=$WEBSOCKIFY_VER"
    echo "         Falling back to whatever apt resolves. Flags are verified below."
    apt-get install -y x11vnc novnc python3-websockify "${EXTRA_PKGS[@]}"
fi

# Prove the flags this installer depends on are accepted by the x11vnc build
# that actually landed. -nograbs was dropped precisely because it does not
# exist on every build and makes x11vnc exit immediately with "unrecognized
# option(s)" — which from the outside looks like x11vnc mysteriously dying on
# every restart. Catch that here, at install time, rather than in production.
X11VNC_FLAGS=(-noshm -noscr -nowf -nowcr -nopw -forever -shared)
if x11vnc "${X11VNC_FLAGS[@]}" -help 2>&1 | grep -qi "unrecognized option"; then
    echo "ERROR: this x11vnc build rejects one of the flags this installer uses:"
    echo "       ${X11VNC_FLAGS[*]}"
    echo "       Check which with: x11vnc ${X11VNC_FLAGS[*]} -help"
    exit 1
fi
echo "x11vnc flag set accepted by $(x11vnc -version 2>&1 | head -1)."

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
    vs-user: "${VS_NAME}"
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
# Attaches x11vnc to whichever graphical session is ACTIVE at the moment this
# runs, then execs into it and gets out of the way. No watchdog, no polling
# after startup, no signals ever sent.
#
# It therefore does NOT follow a fast user switch. Switching users leaves
# x11vnc pointed at the old session, which stays alive and backgrounded on
# its own display — so the viewer keeps seeing that session (stale frame,
# black, or its lock screen), NOT the user now on screen. Logging out is
# what moves the share: the X server dies, x11vnc dies with it, systemd
# restarts this script, and the loop below attaches to the next login.
#
# The only loop here runs BEFORE x11vnc starts — waiting for a usable
# session to exist (fresh boot, or sitting at the GDM greeter). It reads
# logind and /proc; it does not touch any process.

POLL_SECONDS=5

# Print "<user> <display>..." — the user currently on the seat, followed by
# EVERY display utmp lists for them, or nothing.
#
# Two lookups, because neither alone is reliable here:
#   - logind knows which session is *active* (on screen) vs merely *online*
#     (logged in, backgrounded). Fast user switching leaves the previous
#     user's X server alive, so "an X server that answers on :0/:1/:2" is
#     not the same question as "the one on screen".
#   - logind's own Display property comes back empty for X11 sessions on
#     some GDM versions, so the display number itself comes from `who`
#     (utmp), which reports it as the TTY field, e.g. "prod :1".
#
# All candidates, not just the first: an unclean logout (crash, power cut,
# killed session) leaves a stale utmp row behind, so the active user can
# have two ":N" entries and utmp order does not say which one is live.
# Taking the first match blind meant picking the dead display, failing the
# xdpyinfo probe, and then retrying the exact same lookup every 5s forever —
# `who` never changes, so it could not self-heal. The caller probes each
# candidate instead. Safe because these are all rows for the ONE user logind
# already told us is active; this does not reintroduce "any X server that
# answers", it only disambiguates among that user's own entries.
active_session() {
    local session state type seat user uid displays
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
        displays=$(who | awk -v u="$user" '$1==u && $2 ~ /^:[0-9]+$/ {printf "%s ", $2}')
        [[ -n "$displays" ]] || continue
        echo "$user $displays"
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

# Wait for a usable active session. xdpyinfo is the arbiter: a display only
# counts once it actually answers, which is what filters out a stale utmp row
# left behind by an unclean logout.
X_DISPLAY=""
while true; do
    if read -r USER_NAME DISPLAY_CANDIDATES < <(active_session); then
        USER_UID=$(id -u "$USER_NAME")
        USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
        if XAUTH=$(find_xauth "$USER_UID" "$USER_HOME"); then
            # Unquoted on purpose — DISPLAY_CANDIDATES is a space-separated list.
            for candidate in $DISPLAY_CANDIDATES; do
                if XAUTHORITY="$XAUTH" DISPLAY="$candidate" xdpyinfo >/dev/null 2>&1; then
                    X_DISPLAY="$candidate"
                    break
                fi
                echo "Display $candidate listed for $USER_NAME but not answering (stale utmp entry?) — trying next."
            done
            [[ -n "$X_DISPLAY" ]] && break
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
#
# exec, not background-and-watch: x11vnc becomes this unit's main process,
# so there is nothing left polling the session and nothing holding a PID to
# signal later. When the X server goes away at logout, x11vnc exits, the
# unit stops, and Restart=always runs this script again from the top.
exec /usr/bin/x11vnc \
    -display "$X_DISPLAY" \
    -auth "$XAUTH" \
    -noshm -noscr -nowf -nowcr \
    -nopw -forever -shared \
    -rfbport 5900 -localhost
WRAPPER
chmod +x /usr/local/bin/x11vnc-start.sh

# After=network.target, NOT graphical.target: graphical.target itself requires
# multi-user.target, so ordering after it while being WantedBy=multi-user.target
# is a dependency cycle. systemd breaks such cycles by deleting a job, which
# silently left this service dead after boot.
cat > /etc/systemd/system/x11vnc.service <<EOF
[Unit]
Description=x11vnc — shares the desktop session active at attach time (reattaches on logout, not on user switch)
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
# 127.0.0.1:${NOVNC_PORT}, NOT a bare port. websockify's syntax is
# "[source_addr:]source_port target_addr:target_port" — omitting source_addr
# binds 0.0.0.0, which published the full noVNC client and a proxy to the
# desktop on the plant LAN with no authentication at all, bypassing Teleport's
# auth, RBAC and audit entirely. x11vnc itself was already safe via -localhost;
# this port was the exposed one.
ExecStart=${WEBSOCKIFY_BIN} --web /usr/share/novnc 127.0.0.1:${NOVNC_PORT} localhost:${VNC_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ── The switch watcher (v4) ──────────────────────────────────────────────────
# A SEPARATE unit, deliberately not folded into the x11vnc wrapper. The wrapper
# is x11vnc.service's own main process, so it cannot restart its own unit — and
# more importantly, a self-restarting wrapper loses all its state on every
# restart, so it cannot enforce a settle delay ACROSS one. This watcher never
# restarts, so it can.
#
# It sends no signals. Its only action is `systemctl restart x11vnc`.
cat > /usr/local/bin/x11vnc-watch.sh <<'WATCHER'
#!/bin/bash
# Restart x11vnc when the active graphical session has changed AND the new
# session has fully settled.
#
# "Settled" is four separate conditions, each of which exists because of a
# specific way an earlier version got this wrong:
#
#   1. A real human session is active on the seat (uid >= 1000, has a seat).
#      Rejects the GDM greeter and SSH logins.
#   2. LockedHint=no — the user has actually finished logging in or unlocking.
#      This matters most for switching BACK: returning to an existing session
#      makes it `active` while its LOCK SCREEN is still up. Without this gate
#      we would reattach during the unlock, not after it.
#   3. Its X display answers xdpyinfo.
#   4. All of the above hold for SETTLE_POLLS consecutive checks.
#
# Be aware of what actually gates each case. Switching to a FRESH login is
# gated by all four. Switching BACK to an existing session is gated only by
# 2 and 4 — that session's X server never died, so xdpyinfo answers instantly
# and proves nothing. And LockedHint flips the moment the password is
# accepted, which is not the moment mutter has finished reacquiring DRM
# master. So on the switch-back path, SETTLE_POLLS is doing nearly all the
# work. If the experiment fails, raise it here (10 = ~20s) and retest before
# concluding the problem is residue rather than timing.
#
# And one thing it must NOT do: act when there is no active session. That
# state IS the transition — mid-switch, with the greeter up, nothing qualifies
# for a few seconds. v2 treated it as a reason to tear down and therefore fired
# dead-centre of every single switch. Here it resets the counter and waits.

POLL_SECONDS=2
SETTLE_POLLS=3          # consecutive agreeing polls (~6s) before acting
COOLDOWN_SECONDS=20     # after a restart, ignore everything for this long

# Which display is x11vnc actually attached to right now? Read it from the
# process's own cmdline rather than tracking it in a file — the process is the
# only authority on what it is really pointed at, and a file would drift.
# Returns non-zero while the wrapper is still in its wait loop (cmdline is the
# shell script, no -display yet), which correctly means "nothing to reattach".
current_vnc_display() {
    local pid args
    pid=$(systemctl show x11vnc -p MainPID --value 2>/dev/null)
    [[ -n "$pid" && "$pid" != "0" ]] || return 1
    args=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null) || return 1
    [[ "$args" =~ -display[[:space:]]+(:[0-9]+) ]] || return 1
    echo "${BASH_REMATCH[1]}"
}

find_xauth() {
    local uid="$1" home="$2" f
    for f in "/run/user/${uid}/gdm/Xauthority" /run/user/${uid}/.mutter-Xwaylandauth* "${home}/.Xauthority"; do
        [[ -r "$f" ]] && { echo "$f"; return 0; }
    done
    return 1
}

# Print the display of the settled active session, or return non-zero.
settled_display() {
    local session state type seat user uid locked home xauth displays d
    for session in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
        state=$(loginctl show-session "$session" -p State --value 2>/dev/null || true)
        [[ "$state" == "active" ]] || continue
        type=$(loginctl show-session "$session" -p Type --value 2>/dev/null || true)
        [[ "$type" == "x11" || "$type" == "wayland" ]] || continue
        seat=$(loginctl show-session "$session" -p Seat --value 2>/dev/null || true)
        [[ -n "$seat" ]] || continue
        user=$(loginctl show-session "$session" -p Name --value 2>/dev/null || true)
        uid=$(id -u "$user" 2>/dev/null || echo -1)
        [[ "$uid" -ge 1000 ]] || continue
        locked=$(loginctl show-session "$session" -p LockedHint --value 2>/dev/null || true)
        [[ "$locked" == "no" ]] || continue
        home=$(getent passwd "$user" | cut -d: -f6)
        xauth=$(find_xauth "$uid" "$home") || continue
        displays=$(who | awk -v u="$user" '$1==u && $2 ~ /^:[0-9]+$/ {printf "%s ", $2}')
        for d in $displays; do
            if XAUTHORITY="$xauth" DISPLAY="$d" xdpyinfo >/dev/null 2>&1; then
                echo "$d"
                return 0
            fi
        done
    done
    return 1
}

PENDING=""
PENDING_COUNT=0
COOLDOWN_UNTIL=0

echo "Switch watcher started (poll ${POLL_SECONDS}s, settle ${SETTLE_POLLS} polls, cooldown ${COOLDOWN_SECONDS}s)."

while true; do
    sleep "$POLL_SECONDS"

    (( SECONDS < COOLDOWN_UNTIL )) && continue

    # No settled session => we are mid-transition. Reset and wait. Never act.
    if ! target=$(settled_display); then
        PENDING=""
        PENDING_COUNT=0
        continue
    fi

    # x11vnc not attached to anything yet — its own wrapper is still looking
    # for a session and will find this one on its own. Nothing to do.
    if ! current=$(current_vnc_display); then
        PENDING=""
        PENDING_COUNT=0
        continue
    fi

    if [[ "$target" == "$current" ]]; then
        PENDING=""
        PENDING_COUNT=0
        continue
    fi

    if [[ "$target" == "$PENDING" ]]; then
        PENDING_COUNT=$((PENDING_COUNT + 1))
    else
        PENDING="$target"
        PENDING_COUNT=1
        echo "Active session moved to $target (x11vnc is on $current) — waiting for it to settle."
    fi

    if (( PENDING_COUNT >= SETTLE_POLLS )); then
        echo "$target settled across ${SETTLE_POLLS} polls — restarting x11vnc to reattach."
        systemctl restart x11vnc
        PENDING=""
        PENDING_COUNT=0
        COOLDOWN_UNTIL=$((SECONDS + COOLDOWN_SECONDS))
    fi
done
WATCHER
chmod +x /usr/local/bin/x11vnc-watch.sh

cat > /etc/systemd/system/x11vnc-watcher.service <<'EOF'
[Unit]
Description=Reattach x11vnc after a user switch, once the new session has settled
After=network.target

[Service]
ExecStart=/usr/local/bin/x11vnc-watch.sh
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
systemctl enable x11vnc websockify x11vnc-watcher
systemctl restart x11vnc websockify x11vnc-watcher

echo "=== [6/6] Starting Teleport ==="
systemctl enable teleport

# --insecure makes the agent skip TLS verification of the proxy certificate —
# it accepts any cert, including an attacker's. That is fine against a
# self-signed dev proxy, and unacceptable against a real domain: anyone able to
# MITM or DNS-spoof the proxy hostname on the plant network could impersonate
# it and every agent would accept. (ca_pin protects the initial JOIN by
# verifying the cluster CA; it does not cover ongoing proxy connections.)
#
# Decided from the proxy address rather than left as a manual step, so the
# production cutover cannot forget it: bare IPs and nip.io are dev, a real
# domain is not.
TELEPORT_EXTRA_FLAGS=""
if [[ "$PROXY_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$PROXY_HOST" == *.nip.io || "$PROXY_HOST" == *.sslip.io ]]; then
    TELEPORT_EXTRA_FLAGS=" --insecure"
    echo "Proxy '${PROXY_HOST}' looks like a dev address — enabling --insecure (no TLS verification)."
else
    echo "Proxy '${PROXY_HOST}' is a real domain — TLS certificate verification ENABLED."
fi

mkdir -p /etc/systemd/system/teleport.service.d/
cat > /etc/systemd/system/teleport.service.d/insecure.conf <<DROPIN
[Service]
ExecStart=
ExecStart=/usr/local/bin/teleport start --config /etc/teleport.yaml --pid-file=/run/teleport.pid${TELEPORT_EXTRA_FLAGS}
DROPIN
systemctl daemon-reload

systemctl restart teleport
sleep 4

# ── Health check ─────────────────────────────────────────────────────────────
# Across 200 machines you cannot inspect each one by hand, and the failure
# modes here are quiet: x11vnc retrying forever with no display to attach to,
# websockify bind-looping, teleport failing to join. Previously this script
# printed "VS setup complete" in every one of those cases. Assert instead, and
# exit non-zero so a provisioning run surfaces the machine that needs looking
# at.
echo "=== Health check ==="
HEALTH_FAILED=0
check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  OK    $label"
    else
        echo "  FAIL  $label"
        HEALTH_FAILED=1
    fi
}

check "teleport.service active"        systemctl is-active --quiet teleport
check "x11vnc.service active"          systemctl is-active --quiet x11vnc
check "websockify.service active"      systemctl is-active --quiet websockify
check "x11vnc-watcher.service active"  systemctl is-active --quiet x11vnc-watcher
check "xdpyinfo present"               command -v xdpyinfo

# Give x11vnc a moment to find a session and bind before asserting on ports.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    ss -ltn "sport = :${VNC_PORT}" 2>/dev/null | grep -q LISTEN && break
    sleep 2
done

if ss -ltn "sport = :${VNC_PORT}" 2>/dev/null | grep -q LISTEN; then
    echo "  OK    x11vnc listening on ${VNC_PORT}"
else
    echo "  FAIL  x11vnc is NOT listening on ${VNC_PORT} — it has not attached to a display."
    echo "        Usually means no Xorg session yet (reboot pending?) or a Wayland session."
    echo "        Check: journalctl -u x11vnc -n 30"
    HEALTH_FAILED=1
fi

# Must be bound to loopback ONLY. A 0.0.0.0 bind here exposes the desktop to
# the whole plant network with no authentication.
NOVNC_BIND=$(ss -ltn "sport = :${NOVNC_PORT}" 2>/dev/null | awk 'NR>1 {print $4}' | head -1)
if [[ -z "$NOVNC_BIND" ]]; then
    echo "  FAIL  websockify is NOT listening on ${NOVNC_PORT}"
    HEALTH_FAILED=1
elif [[ "$NOVNC_BIND" == 127.0.0.1:* || "$NOVNC_BIND" == "[::1]:"* ]]; then
    echo "  OK    websockify bound to loopback only ($NOVNC_BIND)"
else
    echo "  FAIL  websockify is bound to $NOVNC_BIND — EXPOSED TO THE NETWORK."
    echo "        The desktop is reachable without authentication. Do not deploy."
    HEALTH_FAILED=1
fi

echo ""
echo "=============================="
if [[ "$HEALTH_FAILED" -ne 0 ]]; then
    echo "VS setup FINISHED WITH FAILURES: ${VS_NAME}"
    echo "Review the FAIL lines above before putting this machine into service."
    echo "=============================="
    exit 1
fi
echo "VS setup complete: ${VS_NAME}"
echo "SSH:     Teleport → Servers → ${VS_NAME}"
echo "Desktop: Teleport → Applications → ${VS_NAME}"
echo ""
echo "IDENTITY: this VS is '${VS_NAME}' — the first linux user (UID 1000)."
echo "  Stable by design: re-running this installer from any account, including"
echo "  a 'customer' desktop session, produces the same name. SSH access is"
echo "  granted for '${VS_NAME}' only."
echo ""
echo "USER SWITCHING: the screen share follows a fast user switch on its own,"
echo "  independently of the identity above. Expect ~10-25s of black screen"
echo "  while the new session settles, then it reattaches. No logout needed."
echo "  Reload the Teleport app tab if it stays blank — the browser client does"
echo "  not always reconnect by itself after x11vnc restarts."
echo ""
echo "  The delay is the safety mechanism, not slack. Reattaching during the"
echo "  switch is what broke GDM in earlier versions. SETTLE_POLLS lives in"
echo "  /usr/local/bin/x11vnc-watch.sh — do not shorten it casually."
echo ""
echo "  Watch it live:  journalctl -u x11vnc -u x11vnc-watcher -f"
echo "  Roll back to the no-auto-switch build:  sudo bash setup-v3.sh"
echo ""
echo "  Roll back any time with: sudo bash setup-v3.sh"

# The Wayland fix above only lands at the next GDM start. If the session
# running RIGHT NOW is Wayland, x11vnc cannot attach to it and is currently
# sitting in its retry loop — install succeeded, screen share does not work
# yet. Say so loudly rather than printing a clean "complete" over a node that
# will look healthy in Teleport and show nothing when someone connects.
if [[ "$SESSION_TYPE_DETECTED" == "wayland" ]]; then
    echo ""
    echo "*** REBOOT REQUIRED — SCREEN SHARE IS NOT WORKING YET ***"
    echo "  This machine's current session is Wayland. Wayland is now disabled"
    echo "  at GDM, but that only applies from the next login. Until this node"
    echo "  is rebooted (or GDM restarted), x11vnc has no X display to attach"
    echo "  to and the Teleport Desktop app will show nothing."
    echo "  Verify after reboot:  systemctl status x11vnc"
fi
echo "=============================="
