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
# Design note (v4): v3 plus a separate watcher unit that reattaches x11vnc
# after a user switch — but only once the new session has FULLY SETTLED.
#
# v4 is an experiment with a specific question to answer. Observed history:
#   v1  killed x11vnc the instant a switch was detected          -> GNOME broke
#   v2  exited instead, systemd's cgroup teardown killed it      -> GNOME broke
#   v3  never tears down at all                                  -> nothing breaks,
#                                                                   but never follows
#
# In v1/v2 the switch AWAY worked fine — the new user's screen appeared
# correctly. The breakage showed up on switching BACK to the earlier user.
# Two mechanisms explain that, and they need different fixes:
#
#   (a) RESIDUE. Killing x11vnc while it is attached to a session leaves
#       state behind in that session's X server (XTEST fake-input state is
#       server-global and is NOT reset when a client disconnects; x11vnc also
#       disables keyboard autorepeat and warns its own restore is unreliable).
#       Invisible while that session is backgrounded; surfaces on return.
#
#   (b) TIMING. x11vnc reattaches to the returning session while it is still
#       reacquiring DRM master, and disturbs the handoff.
#
# v4 tests (b): the teardown and the reattach both happen well AFTER the
# transition finishes, instead of inside it. If switching back now works, it
# was (b) and this is the fix. If it still breaks, it was (a) — and the answer
# is a per-session agent architecture (one x11vnc per user, owned by that
# user's own session), not more retiming.
#
# Deliberately NOT changing the x11vnc flags here (no -repeat, no -clear_all).
# Those target mechanism (a). Changing both at once would make the result
# uninterpretable.
#
# Rollback: re-run setup-v3.sh. It ships no watcher, and its install disables
# and removes this one.
#
# Consequence, and this is the intended operating procedure: switching users
# while a VNC session is live does NOT move the share to the new user. The
# viewer keeps seeing the old, now-backgrounded session — a stale frame,
# black, or that user's lock screen, depending on DPMS and whether GNOME
# locked on switch. Note this means a remote operator who connects after a
# switch may be looking at the PREVIOUS user's desktop, not the current one.
# To hand the machine over, LOG OUT rather than switch users: the X server
# dies, x11vnc dies with it, systemd restarts this wrapper, and it attaches
# to whoever logs in next.
#
# Why give up automatic switching: every version that reattached mid-switch
# (v1 killed x11vnc directly, v2 exited and let systemd's cgroup teardown do
# it) left the returned-to GNOME session broken — first a GDM display-switch
# crash, then a desktop that renders but accepts no input.
#
# Scope of the fix, stated honestly: under the documented procedure (logout,
# never switch) x11vnc is never running during a VT switch, so the failure
# window does not occur. If someone switches ANYWAY with a viewer attached,
# v3 does not protect that path — x11vnc keeps polling the backgrounded
# display with XGetImage right through the switch, which is the exact
# condition v1/v2 tried to mitigate and v3 has no mitigation for. v3 relies
# on the operating procedure, not on being safe under a switch.

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
# This matters most for v3's logout-to-hand-over flow: the whole point is that
# the NEXT user to log in gets picked up automatically, and that next user is
# by definition not necessarily $DESKTOP_USER.
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
ExecStart=${WEBSOCKIFY_BIN} --web /usr/share/novnc ${NOVNC_PORT} localhost:${VNC_PORT}
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
echo "v4 EXPERIMENT: the screen share now follows a user switch, but only after"
echo "  the new session has settled — logged in or unlocked, X answering, stable"
echo "  for ~6s. Expect roughly 10-25s of black screen across a switch, then it"
echo "  reattaches on its own. Reload the Teleport app tab if it stays blank."
echo ""
echo "  WHAT TO TEST: switch away, then switch BACK to the first user. Switching"
echo "  away already worked in v2 — switching back is what broke GDM."
echo ""
echo "  Before you switch back, open an SSH session and leave this running:"
echo "    journalctl -u x11vnc -u x11vnc-watcher -f"
echo ""
echo "  If it BREAKS, run these from SSH before rebooting:"
echo "    xset q on the broken session is the direct residue check —"
echo "    'auto repeat: off' means x11vnc left state behind when it was killed."
echo "      sudo -u <user> DISPLAY=:<N> XAUTHORITY=/run/user/<uid>/gdm/Xauthority \\"
echo "          xset q | grep -i -A1 'auto repeat'"
echo "      journalctl _COMM=gnome-shell --since '5 min ago' -o short-precise | tail -40"
echo "      coredumpctl list --since '5 min ago'"
echo ""
echo "  A failure does NOT immediately mean residue. Retry once with a longer"
echo "  settle before concluding — edit SETTLE_POLLS=10 in"
echo "  /usr/local/bin/x11vnc-watch.sh, then: systemctl restart x11vnc-watcher"
echo "  (no reinstall needed). If it still breaks at ~20s, it is residue, and"
echo "  the fix is one x11vnc per user session rather than one shared one."
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
