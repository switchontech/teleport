# Teleport Server — Setup & Ops

## What this is

One-shot Docker-based deployment of our custom Teleport fork
`switchontech/teleport`, based on stable `v18.10.0`

## Architecture

- **Two-stage Dockerfile**: builder stage (Ubuntu 22.04 + Go 1.25.11 + Rust
  1.94.0 + Node 24.16.0, all installed via direct vendor downloads, not
  Debian's mirrors — those timeout on this network) compiles
  `teleport`/`tctl`/`tsh` from `/src` (repo root). Runtime stage is thin
  Ubuntu 22.04 with just the 3 binaries + entrypoint.
- **`docker-entrypoint.sh`** generates `/etc/teleport.yaml` from env vars
  (`.env`) on every container start, then execs `teleport start`.
- **`docker-compose.yml`**: single service `teleport` (container name
  `teleport_deployment`), `restart: unless-stopped` for crash/reboot
  recovery, named volume `teleport_data` for `/var/lib/teleport`
  (certs/CA/state — survives rebuilds).
- BuildKit cache mounts (`--mount=type=cache`) keep the Go module/build
  cache across rebuilds — first build ~15-20 min, later code-only changes
  much faster.

## Prerequisites (host)

- Docker + docker compose plugin, user in the `docker` group.
- **Do NOT run `setup.sh` with `sudo`** — sudo resets `$(id -u)` inside the
  build, which breaks an internal `useradd` step.
- No Go/Rust/Node needed on host — all toolchains live inside the build
  container.
- The `ssh-access-watcher` step additionally needs `go` on the host to
  compile a small daemon — `install.sh` auto-installs Go 1.25.11 from
  go.dev if it's not already present.

## One-shot setup

```bash
cd teleport/
bash setup.sh
```

First run: no `.env` exists yet → copies `.env.example` → `.env`, exits,
tells you to edit it. Edit `.env` (reference below), re-run.

`setup.sh` (→ `deploy/server/build-and-run.sh`) runs these steps in order:

1. Check `.env` exists
2. `docker compose up -d --build` — build + start, poll `/webapi/ping`
   until healthy (up to 15 min)
3. `apply-roles.sh` — pushes all `roles/*.yaml` to the cluster
4. `create-admin.sh` — creates `$ADMIN_USER` (roles `super-admin,ssh-access`)
   if not already present, prints a signup URL
5. `bake.sh` — bakes the live `PROXY`/`TOKEN`/`CA_PIN` into
   `../vs/setup.sh`, **and** refreshes the `ssh-access-watcher` machine
   identity (see Automation below)
6. `automation/ssh-access-watcher/install.sh` (sudo) — builds + installs
   the watcher as a systemd service

## `.env` reference

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

## RBAC — the 4 roles (`roles/*.yaml`)

| Role | Scope | Logins | Notes |
|---|---|---|---|
| `super-admin` | root+customer, full cluster admin+audit | static `root`, `customer` | merged built-in editor+auditor rules; `enhanced_recording: [command, network]` |
| `cloud-admin-full-access` | customer only | static `customer` | manage nodes/apps, view audit, no root |
| `cloud-read-access` | customer only | static `customer` | read-only |
| `ssh-access` | supplementary | static literal list — `customer` plus one entry per VS desktop username | attach alongside a primary role; auto-updated by `ssh-access-watcher` when a new VS joins |

Deliberately **no** per-VS custom roles and **no** per-user trait-based
logins — both were tried and rejected as unmaintainable at scale.

## Automation: ssh-access-watcher

- Small Go daemon (`automation/ssh-access-watcher/`), runs as its own
  systemd service on the server host.
- Watches Teleport node registrations; when a VS joins with a `vs-user`
  label not already in `ssh-access`'s logins, appends it and re-applies the
  role automatically. No manual role edit needed when a new VS comes
  online.
- Authenticates to the cluster with a signed identity file
  (`secrets/identity`), **not** a join token — that identity is only valid
  against the CA that signed it.
- **Gotcha**: any time the cluster CA changes (fresh `teleport_data`
  volume — full rebuild/reset), this identity goes stale exactly like a
  VS's cached identity does. `bake.sh` refreshes it on every run: ensures
  the `ssh-access-watcher` Teleport user exists, re-signs the identity, and
  `docker cp`s it out of the container to the host-side `secrets/` dir.
  Re-run `install.sh` afterward (or just re-run `setup.sh`) so the service
  picks up the fresh identity — `install.sh` always restarts it.

## Day-2 operations

- Code change in the fork → `bash setup.sh` again (rebuild + redeploy,
  idempotent — skips admin creation if the user already exists)
- Role yaml change → `bash apply-roles.sh` alone
- New VS joins → its `ssh-access` login is added automatically by the
  watcher, no manual step
- `PUBLIC_ADDR`/token/CA changed → `bash bake.sh` alone, then re-copy
  `deploy/vs/setup.sh` to VS machines
- Logs: `docker compose logs -f` (from `deploy/server/`)
- Full reset (new CA): `docker compose down -v` (**wipes** `teleport_data`)
  then `bash setup.sh` — every VS then needs `uninstall.sh` + `setup.sh`
  again, and `bake.sh` needs a re-run

## Troubleshooting (real issues hit building this)

- **`useradd` exit 4 / "UID not unique"**: caused by running with `sudo` —
  it resets `$(id -u)` to 0, breaking a build step. Run as plain
  `bash setup.sh` (needs the `docker` group only).
- **Container name/port conflicts with an old cluster**: the container is
  named `teleport_deployment` (not `teleport`) specifically to avoid
  clashing with a stale leftover container.
- **Healthcheck never passes despite Teleport logging a healthy startup**:
  a container object created during an earlier failed run (e.g. a port
  conflict) can be `start`ed again but never actually get its ports bound —
  Docker binds ports at container *create* time, not start time. Fix:
  `docker compose down` then a fresh `docker compose up -d --build`.
- **VS shows "bad certificate" / connection reset after a rebuild**:
  expected — a fresh volume means a fresh CA. Needs a VS-side
  `uninstall.sh` + `setup.sh` rejoin.
- **Debian mirror timeouts during build** (`deb.debian.org` unreachable):
  root cause of an entire abandoned build approach (the official
  `build.assets` Docker build). This Dockerfile deliberately avoids
  Debian's mirror network entirely (Ubuntu apt + go.dev/rustup.rs/nodejs.org
  direct downloads) — seeing mirror timeouts again means something drifted
  back toward the abandoned path.

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
  copies are still present but unused, kept only until this setup is
  confirmed fully working end-to-end.
- Designed and implemented the 4-role RBAC model above, replacing two
  earlier designs that were tried and explicitly rejected: per-VS custom
  roles, and per-user trait-based login management.
- Built `ssh-access-watcher` to automate the one recurring manual step
  (adding a new VS's login to `ssh-access`), including handling its own
  identity going stale on cluster CA resets.
