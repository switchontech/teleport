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
4. Writes `/etc/teleport.yaml`: SSH service (labels `vs-id`, `vs-user` =
   detected active desktop user, `env=plant`) + app service exposing noVNC
   at `<vs-name>.<proxy-host>`
5. Sets up x11vnc + websockify as **user** systemd services
   (`systemctl --user`) under the detected active graphical desktop user
   (not whoever ran sudo) — auto-detects the display (`:0`/`:1`/`:2`) and
   Xauth file at runtime
6. Enables + restarts the `teleport` systemd service via a drop-in
   (`--insecure` flag — internal network, self-signed proxy cert)

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
sudo bash setup.sh [vs-name]      # defaults to hostname
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
sudo bash setup.sh <vs-name>
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

## What's been done so far

- Kept this installer bare-systemd/no-Docker by design (unlike the
  server) — Teleport's own package manages itself as a systemd service,
  matching upstream's simplest official deployment shape for edge nodes.
- Hardened `uninstall.sh` to always do a full wipe (it briefly had a
  lighter `--rejoin` mode — rejected, since a VS should never carry
  forward stale CA/identity state).
- Explicitly rejected a per-VS custom-role generator
  (`vs-access-<name>` roles + a sync script) in favor of the static
  `ssh-access` role + the automated watcher described above.
- Moved this installer (and its `uninstall.sh` counterpart) from the
  outer `teleport_deployment/vs-setup/` wrapper repo into this fork's
  `deploy/vs/`, consolidating with the server-side tooling.
