# Teleport VS (Vision System) — Setup & Ops

## What this is

One-shot installer (`setup.sh`) that turns a bare Ubuntu VS desktop machine
into a Teleport SSH node + a remote-desktop "app" (VNC via x11vnc + noVNC),
joined to the central cluster. No Docker on VS machines — bare systemd
install, same shape as Teleport's own official package deployment.

## What `setup.sh` does (in order)

1. Installs Teleport 18.10.0 via the official install script
2. Installs pinned `x11vnc` + `novnc` + `python3-websockify` — versions are
   pinned per Ubuntu release (22.04 and 24.04 supported; an unpinned
   install silently drifts per-machine — apt resolves different package
   versions on different releases — so an unsupported release hard-fails
   rather than guessing)
3. Checks kernel BTF support (`/sys/kernel/btf/vmlinux`) — disables
   `enhanced_recording` (BPF command/network session logging) if missing,
   rather than failing to start
4. Writes `/etc/teleport.yaml`: SSH service (labels `vs-id` = this
   machine's hostname, `vs-user` = detected active desktop user,
   `env=plant`) + app service exposing noVNC at `<hostname>.<proxy-host>`
5. Sets up x11vnc + websockify as **user** systemd services
   (`systemctl --user`) under the detected active graphical desktop user
   (not whoever ran sudo) — auto-detects the display (`:0`/`:1`/`:2`) and
   Xauth file at runtime
6. Enables + restarts the `teleport` systemd service via a drop-in
   (`--insecure` flag — internal network, self-signed proxy cert)

## Remote desktop (VNC) — how it works

The VS's desktop is exposed as a Teleport **app**, not as a raw VNC port on
the network. Nothing about this stack is directly reachable except through
Teleport's own authenticated, audited proxy tunnel.

**Components, wired together by `setup.sh`:**

- **x11vnc** — grabs the real X11 display and serves it as VNC on
  `127.0.0.1:5900` (`-localhost`, never bound to a real network interface).
- **websockify** — bridges that raw VNC/TCP socket to a WebSocket, because
  browsers can't speak raw VNC. Serves noVNC's static HTML/JS client
  (`--web /usr/share/novnc`) and proxies its WebSocket traffic through to
  `localhost:5900`, listening on `127.0.0.1:6080`.
- **noVNC** — the actual in-browser VNC client (HTML5 canvas + JS), served
  by websockify above. This is what the "Desktop" tile in the Teleport UI
  actually loads.
- **Teleport `app_service`** — registers `http://localhost:6080/vnc_auto.html?resize=scale`
  as an app named after the VS. Teleport terminates the real internet-
  facing TLS, authenticates the user, checks their role, records the
  session, and reverse-tunnels the request back to this one local port.

**Request path**: browser → Teleport proxy (TLS, auth, RBAC, audit) →
reverse tunnel → VS's Teleport agent → `localhost:6080` (websockify) →
`localhost:5900` (x11vnc) → the real X11 display. VNC/websockify never
touch the network directly — Teleport is the only thing actually exposed,
which is also why the desktop shows up in the audit log like any other
session.

**Why it needs runtime auto-detection, not a fixed config:**

- **Which display?** The wrapper script (`/usr/local/bin/x11vnc-start.sh`)
  probes `:0`, `:1`, `:2` with `xdpyinfo` until one answers, and retries
  every 5s if none do yet (e.g. box just booted, nobody's logged in yet).
- **Which Xauth cookie?** GDM puts it in different places depending on
  session type — the wrapper checks
  `/run/user/*/gdm/Xauthority`, `/run/user/*/.mutter-Xwaylandauth*`, and
  `/home/*/.Xauthority` in order, uses whichever is readable first.
- **Which user's desktop?** `setup.sh` walks `loginctl list-sessions`,
  picks whichever session is `active` + type `x11`/`wayland` + UID ≥ 1000
  (excludes GDM's own greeter session, which can otherwise look like an
  "active" session too). That's the desktop that gets shared — the
  machine's real logged-in user, not whoever happened to run `sudo`.

**Why user-level systemd, not system-level:** x11vnc has to run *as* the
desktop user to see their X session at all — a system-level service
running as root can't attach to another user's display. Both units live
under `systemctl --user` for `$DESKTOP_USER`, and
`loginctl enable-linger $DESKTOP_USER` keeps that user's systemd instance
(and so these services) alive even with no active login — otherwise
`--user` services die the moment the session ends.

**Hardening / conflicts handled:**

- **`gnome-remote-desktop`** ships enabled by default on GNOME and also
  wants port 5900 — `setup.sh` stops and disables it so it can't fight
  x11vnc for the port.
- **Stray processes from a previous run** (a manual test, an earlier
  failed `setup.sh` attempt) can be left holding 5900/6080, which would
  otherwise put the managed systemd units into an endless
  bind-fails-restart loop — `setup.sh` force-kills both ports
  (`fuser -k`) before starting its own instances.
- **`websockify` binary path** varies by how it got installed —
  `setup.sh` prefers the `python3-websockify` package's `websockify`
  binary, falling back to noVNC's bundled
  `/usr/share/novnc/utils/websockify/run` if that's what's present.
- **Wayland**: x11vnc is an X11 tool — under Wayland it only sees XWayland
  (compatibility-layer) windows, not the compositor's real desktop. There
  is no fix for this short of the user's session being Xorg — `setup.sh`
  detects and warns but can't work around it.

## Prerequisites

- Ubuntu 22.04 or 24.04, GNOME desktop, an active local graphical login.
  Must be **X11**, not Wayland — Wayland sessions only expose XWayland
  windows to x11vnc, not the full desktop. Log the desktop user into an
  "Ubuntu on Xorg" session for full-screen sharing.
- Root/sudo.
- Network reachability to the server's `TUNNEL_PORT` (3024 by default) —
  this is how the VS's reverse tunnel joins the cluster.

## Usage

```bash
scp deploy/vs/setup.sh user@vs-machine:~/
ssh user@vs-machine
sudo bash setup.sh                # VS identity is always this machine's hostname
```

`PROXY`/`TOKEN`/`CA_PIN` are baked into the script's first lines by the
server's `bake.sh` — nothing else to configure, copy the one file and run
it.

## Re-baking (server-side values changed)

If `PUBLIC_ADDR`, the join token, or the cluster CA (any full server
rebuild) changes, re-run on the server:

```bash
bash deploy/server/bake.sh
```

then re-copy the freshly-baked `setup.sh` to each VS and re-run it (safe to
re-run — it's declarative, just rewrites config + restarts services).

## Uninstall

```bash
sudo bash uninstall.sh
```

Full wipe by design — purges the `teleport` package, x11vnc/noVNC/
websockify, **all** local Teleport state (`/var/lib/teleport`, certs,
cached identity), the systemd drop-in dir, and the pid file. Guarantees
`setup.sh` always works cleanly afterward, including rejoining a cluster
with a brand-new CA. (An earlier lighter `--rejoin` mode was deliberately
dropped — a VS should never carry forward stale CA state.)

## After a server-side cluster rebuild (new CA)

The VS's cached identity/certs no longer match the new CA → "bad
certificate" / connection reset. Fix, per VS:

```bash
sudo bash uninstall.sh
# copy the freshly re-baked setup.sh
sudo bash setup.sh
```

## Automatic ssh-access registration

Once a VS joins, the server-side `ssh-access-watcher` daemon sees its
`vs-user` label and automatically appends that username to the
`ssh-access` role's login list — no manual per-VS role edit needed.

## Troubleshooting (real issues hit building this)

- **x11vnc / noVNC ports blocked on repeated `setup.sh` runs**: a stray
  process from a prior run (possibly owned by a different user) can hold
  port 5900/6080 and block the managed instance forever — `setup.sh`
  force-kills both ports before starting its own.
- **`gnome-remote-desktop` conflicts on port 5900**: `setup.sh` explicitly
  stops + disables it.
- **Wayland sessions**: x11vnc only sees XWayland windows, not the whole
  desktop — use an Xorg session for full desktop sharing.
- **Package version drift across Ubuntu releases**: `novnc` is
  `1:1.0.0-5` on 22.04 vs `1:1.3.0-2` on 24.04 (confirmed different) —
  versions are pinned per-release in the script rather than left to apt's
  resolution.

