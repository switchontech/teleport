# Teleport Deployment — Installation & Setup Guide

Covers both halves of this deployment: the central **server** (Docker,
built from this fork's source) and **VS** (Vision System) desktop machines
that join it (bare systemd, no Docker). Deploy the server first, then join
VS machines to it.

Per-directory docs with more detail: [`deploy/server/README.md`](deploy/server/README.md),
[`deploy/vs/README.md`](deploy/vs/README.md).

---

## Architecture at a glance

```
teleport/
├── setup.sh                  # entry point: builds + runs the server
└── deploy/
    ├── server/
    │   ├── Dockerfile, docker-compose.yml, docker-entrypoint.sh
    │   ├── build-and-run.sh  # the real one-shot logic
    │   ├── apply-roles.sh, create-admin.sh, bake.sh
    │   ├── roles/*.yaml      # the 4 RBAC roles
    │   ├── automation/ssh-access-watcher/
    │   └── .env / .env.example
    └── vs/
        ├── setup.sh          # copy this one file to a VS machine
        └── uninstall.sh
```

---

## Server setup

## Features


- **Rebranded, our theme, our UI.** The web console isn't stock Teleport
  — it's our fork, our look, shipped as one of this fork's 3 custom
  commits carried through every rebuild.
- **Command level session monitoring** `enhanced_recording:
  [command, network]` (BPF-based, kernel-level — not shell-history,
  can't be disabled from inside the session) captures every command run
  and every network connection made on every node. Click any session in
  the audit log and watch it back like a video — full terminal replay,
  scrub bar and all. Nothing an SSH session did is invisible after the
  fact.
- **4-role RBAC.** `super-admin` / `cloud-admin-full-access`
  / `cloud-read-access` / `ssh-access` — e
- **Root, locked down.** Root SSH access exists on paper for exactly one
  role (`super-admin`) — everyone else is hard-denied root at the role
  level (`deny: {logins: [root]}`), enforced by Teleport itself, not by
  convention or trust.
- **New VS machine joins → access is already there.** The
  `ssh-access-watcher` daemon watches the cluster live and auto-grants
  the right login the instant a VS registers — no admin ever touches a
  role file to onboard a new machine.
- **One shared role, every VS, one Linux user each.** `ssh-access` maps
  straight onto each VS's real desktop Linux account — the same login a
  human already uses sitting at that machine, not a synthetic Teleport-only
  identity. Access to the VS *is* access as that machine's own user.

### Prerequisites (host)

- **Do not run with `sudo`** — sudo resets `$(id -u)` inside the build and
  breaks an internal `useradd` step.
- No Go/Rust/Node needed on host — the whole toolchain lives inside the
  build container. (Exception: the `ssh-access-watcher` step needs `go` on
  the host to compile a small daemon — `install.sh` auto-installs Go
  1.25.11 from go.dev if it's missing.)

### One-shot install

```bash
cd teleport/
bash setup.sh
```
Edit .env to fill up the IPs, nodename, cluster etc configs for Teleport.

`setup.sh` runs these steps in order (all idempotent, safe to re-run):

1. Check `.env` exists
2. `docker compose up -d --build` — build + start, poll `/webapi/ping`
   until healthy (first build ~15-20 min; later code-only rebuilds reuse
   BuildKit's Go module/build cache and are much faster)
3. `apply-roles.sh` — pushes all `roles/*.yaml` to the cluster
4. `create-admin.sh` — creates `$ADMIN_USER` (roles `super-admin,ssh-access`)
   if not already present, prints a one-time signup URL. Provide an admin user to create a user with that credentials.
5. `bake.sh` — bakes the live `PROXY`/`TOKEN`/`CA_PIN` into
   `deploy/vs/setup.sh`, and refreshes the `ssh-access-watcher` machine
   identity (both go stale on a CA change or new setup of teleport — see Automation below)
6. `automation/ssh-access-watcher/install.sh` (sudo) — builds + installs
   the watcher as a systemd service

### `.env` reference

| Var | Meaning |
|---|---|
| `PUBLIC_ADDR` | host:port VS machines/browsers reach this server on (e.g. `1.2.3.4.nip.io:3080`) |
| `WEB_PORT` / `AUTH_PORT` / `TUNNEL_PORT` | host-side port mappings (3080/3025/3024) |
| `CLUSTER_NAME` | Teleport cluster name |
| `NODENAME` | this auth/proxy node's name |
| `VS_JOIN_TOKEN` | static join token VS machines use — never expires, keep secret |
| `ADMIN_USER` | first admin user created |
| `LOG_LEVEL` | `DEBUG`/`INFO`/`WARN`/`ERROR` |
| `TELEPORT_EXTRA_ARGS` | extra flags appended to `teleport start` |

### Completing admin signup / logging in

`create-admin.sh` prints a one-time invite URL
(`https://<PUBLIC_ADDR>/web/invite/<token>`, valid 1 hour). Open it from a
machine that can route to the server, accept the self-signed cert warning,
set a password + MFA.

- **Verify the proxy is up**: `curl -sk https://<PUBLIC_ADDR>/webapi/ping`
  → should return JSON with an `"auth"` block.
- **Verify the invite token is still valid**:
  `curl -sk https://<PUBLIC_ADDR>/webapi/users/invite/<token>` → JSON with
  user/expiry info if valid, an error if expired/used.
- **If it expired** (user already exists, so `create-admin.sh` won't
  re-run): `docker compose exec -T teleport tctl users reset $ADMIN_USER`
  prints a fresh `/web/reset/<token>` link.
- **Regular login**, once registered: `https://<PUBLIC_ADDR>/web/login`

### RBAC — the 4 roles (`deploy/server/roles/*.yaml`)

| Role | Scope | Logins | Notes |
|---|---|---|---|
| `super-admin` | root+customer, full cluster admin+audit | static `root`, `customer` | merged built-in editor+auditor rules; `enhanced_recording: [command, network]` |
| `cloud-admin-full-access` | customer only | static `customer` | manage nodes/apps, view audit, no root |
| `cloud-read-access` | customer only | static `customer` | read-only |
| `ssh-access` | supplementary | static literal list — `customer` plus one entry per VS desktop username | attach alongside a primary role; auto-updated by `ssh-access-watcher` |

Deliberately **no** per-VS custom roles and **no** per-user trait-based
logins — both were tried and rejected as unmaintainable at scale.

### Automation: ssh-access-watcher

- Runs as its own systemd service on the server host, watches Teleport
  node registrations, and appends a new VS's `vs-user` label value to the
  `ssh-access` role's login list automatically — no manual role edit
  needed when a new VS joins.
- Authenticates with a signed identity file (`secrets/identity`), not a
  join token — that identity is only valid against the CA that signed it.
  **Any cluster CA change (fresh `teleport_data` volume) invalidates it**,
  same as it would a VS's cached identity. `bake.sh` refreshes it every
  run (ensures the `ssh-access-watcher` Teleport user exists, re-signs,
  `docker cp`s it out of the container) — re-run `install.sh` (or
  `setup.sh`) afterward so the service picks up the fresh one.

## Running Teleport day-to-day / applying code changes

**Just running/restarting it (no code change):**

```bash
cd deploy/server
docker compose ps             # status + health
docker compose logs -f        # follow logs (Ctrl-C to stop watching)
docker compose restart        # restart the running container — no rebuild
docker compose down           # stop (keeps the teleport_data volume — certs/CA survive)
docker compose up -d          # start again
```

**You changed something in the fork's source (Go/TypeScript/Rust under
`teleport/`) and want it running:**

```bash
cd deploy/server
docker compose up -d --build
docker compose logs -f
```

Why `--build` and not `restart`: `restart` just restarts the existing
container — same image, same old binary, your change isn't in it. `up -d
--build` re-runs the Dockerfile; the `COPY . /src/` layer hashes your
changed files, so any edited file invalidates that layer and everything
after it (`make ensure-js-deps` / `build-ui` / `build/teleport` etc.)
re-runs and recompiles. BuildKit's cache mounts mean only the affected
parts are slow — a Go-only change skips the JS build entirely, a frontend
change doesn't recompile Go.

Equivalently, `bash setup.sh` (from the repo root) does the same build
step plus re-applies roles/admin/bake/watcher — use that instead of the
plain `docker compose` command if you want the whole chain re-synced, not
just a rebuild. Both are idempotent/safe to re-run.

**Confirming the new build actually took effect:**

- Backend (Go) change: test the actual behavior you changed, or watch
  `docker compose logs -f` for new log lines/output you added.
- Frontend (React/theme) change: hard-refresh the browser
  (`Ctrl-Shift-R`) — the browser caches the old `webassets` bundle
  otherwise, so a normal refresh can still show stale UI even though the
  container rebuilt correctly.
- To confirm a rebuild actually happened (not just a restart of the same
  image): `docker compose images teleport` — check the image ID/created
  timestamp changed versus before your edit.

## VS (Vision System) setup

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

### Prerequisites

- Ubuntu 22.04 or 24.04, GNOME desktop, an active **X11** graphical login
  (not Wayland — x11vnc only sees XWayland windows under Wayland, not the
  full desktop).
- Root/sudo.
- Network reachability to the server's `TUNNEL_PORT` (3024 default) — this
  is how the VS's reverse tunnel joins the cluster.

### Install

```bash
scp deploy/vs/setup.sh user@vs-machine:~/
ssh user@vs-machine
sudo bash setup.sh                # VS identity is always this machine's hostname
```

`PROXY`/`TOKEN`/`CA_PIN` are baked into the script's first lines by the
server's `bake.sh` — nothing else to configure, just copy the one file and
run it.

What it does: installs Teleport 18.10.0 (official install script), pinned
`x11vnc`/`novnc`/`python3-websockify` (version-pinned per Ubuntu release),
checks kernel BTF support (disables `enhanced_recording` if missing rather
than failing to start), writes `/etc/teleport.yaml` (SSH service + an app
service exposing noVNC), sets up x11vnc + websockify as **user** systemd
services under the detected active desktop user, and enables the
`teleport` systemd service.

### Re-baking (server-side values changed)

If `PUBLIC_ADDR`, the join token, or the cluster CA changes, re-run on the
server:

```bash
bash deploy/server/bake.sh
```

then re-copy the freshly-baked `setup.sh` to each VS and re-run it (safe —
declarative, just rewrites config + restarts services).

### Uninstall

```bash
sudo bash uninstall.sh
```

Full wipe by design: purges the `teleport` package, x11vnc/noVNC/
websockify, **all** local Teleport state (`/var/lib/teleport`, certs,
cached identity), the systemd drop-in dir, the pid file. Guarantees
`setup.sh` always works cleanly afterward, including rejoining a cluster
with a brand-new CA.

### After a server-side cluster rebuild (new CA)

VS's cached identity/certs no longer match → "bad certificate" /
connection reset. Per VS:

```bash
sudo bash uninstall.sh
# copy the freshly re-baked setup.sh
sudo bash setup.sh
```

### Automatic ssh-access registration

Once a VS joins, `ssh-access-watcher` (server-side) sees its `vs-user`
label and appends that username to the `ssh-access` role automatically —
no manual per-VS role edit.

---

## Troubleshooting (real issues hit building this)

**Server / build:**
- **`useradd` exit 4 / "UID not unique"**: caused by running `setup.sh`
  with `sudo` — it resets `$(id -u)` to 0, breaking a build step. Run as
  plain `bash setup.sh` (needs the `docker` group only).
- **Debian mirror timeouts during build** (`deb.debian.org` unreachable):
  root cause of an abandoned build approach (the official `build.assets`
  Docker build). The current Dockerfile deliberately avoids Debian's
  mirror network entirely (Ubuntu apt + go.dev/rustup.rs/nodejs.org direct
  downloads) — seeing mirror timeouts again means something drifted back
  toward the abandoned path.
- **`permission denied` / stray root-owned files in the build context**
  (`.pnpm-store`, `build.assets/.cache`, `target`, nested `node_modules`
  under `web/packages/*/node_modules`): leftovers from early build
  experiments run as root, before the `sudo` guard existed. Fixed via
  `.dockerignore` (`**/node_modules`, `.pnpm-store`, `target`,
  `build.assets/.cache`, etc. — none of these are needed in the build
  context, `make ensure-js-deps` reinstalls fresh inside the container
  anyway). If you hit this on a truly fresh clone, it shouldn't recur —
  it only affects this original working tree's history.
  
**VS:**
- **VS shows "bad certificate" / connection reset after a server
  rebuild**: expected — a fresh volume means a fresh CA. Needs a VS-side
  `uninstall.sh` + `setup.sh` rejoin.
- **x11vnc / noVNC ports blocked on repeated `setup.sh` runs**: a stray
  process from a prior run can hold port 5900/6080 forever — `setup.sh`
  force-kills both ports before starting its own.
- **`gnome-remote-desktop` conflicts on port 5900**: `setup.sh` explicitly
  stops + disables it.
- **Wayland sessions**: x11vnc only sees XWayland windows — use an Xorg
  session for full desktop sharing.
- **Package version drift across Ubuntu releases**: `novnc` is
  `1:1.0.0-5` on 22.04 vs `1:1.3.0-2` on 24.04 — pinned per-release in the
  script rather than left to apt's resolution.

---

## What's been done so far

- Forked `switchontech/teleport`, moved off unstable `master`
  (`19.0.0-prealpha.2`) onto stable `v18.10.0` — matches the VS nodes'
  official Teleport version — preserving the fork's 3 custom commits
  (theme rebrand + login-list filter).
- Replaced the official `build.assets` Docker build path (unfixable Debian
  mirror connectivity in this environment) with a hand-rolled two-stage
  Dockerfile that never touches Debian's mirrors.
- Consolidated all deployment tooling — previously split across an outer
  `teleport_deployment/` wrapper repo + git submodule — into this fork
  itself, under `deploy/server/` + `deploy/vs/`. The outer repo's old
  copies are kept until this setup is confirmed fully working end-to-end,
  then retired.
- Designed and implemented the 4-role RBAC model above, replacing two
  earlier designs that were tried and explicitly rejected: per-VS custom
  roles, and per-user trait-based login management.
- Built `ssh-access-watcher` to automate the one recurring manual step
  (adding a new VS's login to `ssh-access`), including handling its own
  identity going stale on cluster CA resets.
- Kept the VS installer bare-systemd/no-Docker by design (unlike the
  server) — matches Teleport's own simplest official deployment shape for
  edge nodes.
- Hardened VS `uninstall.sh` to always do a full wipe (a lighter
  `--rejoin` mode was tried and rejected — a VS should never carry forward
  stale CA/identity state).
