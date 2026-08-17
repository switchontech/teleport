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
5. Sets up x11vnc + websockify as **system-level** services (root) —
   auto-detects the live display and whichever user currently owns it at
   runtime, every time it (re)starts, not just once at install time
6. Installs `x11vnc-watcher.service`, which reattaches the share after a
   user switch once the new session has settled
7. Forces Xorg machine-wide (`WaylandEnable=false` in
   `/etc/gdm3/custom.conf`) plus a per-user AccountsService default —
   x11vnc cannot capture a Wayland desktop, and fails silently if it tries
8. Enables + restarts the `teleport` systemd service via a drop-in
   (`--insecure` flag — internal network, self-signed proxy cert)

## Which script to deploy

`setup-v4.sh` is the current, working installer — it is what the "User
switching" section below describes.

`setup.sh`, `setup-v2.sh` and `setup-v3.sh` are earlier iterations kept for
reference and rollback. `setup-v3.sh` is the known-safe fallback: it never
follows a user switch (the operator must log out to hand the machine over),
but it cannot break GDM. Re-running it also stops, disables and removes the
v4 watcher, so it is a clean rollback.

> **Heads-up:** `deploy/server/bake.sh` hardcodes
> `SETUP_SH="$SCRIPT_DIR/../vs/setup.sh"`, so baking currently stamps the
> proxy/token/CA-pin into `setup.sh` — the *old* v1 script — not
> `setup-v4.sh`. Either promote v4 to `setup.sh` or point `bake.sh` at
> `setup-v4.sh` before rolling out to the fleet, otherwise a baked script
> ships the version that breaks GDM on user switch.

## Remote desktop (VNC) — how it works

The VS's desktop is exposed as a Teleport **app**, not as a raw VNC port on
the network. Nothing about this stack is directly reachable except through
Teleport's own authenticated, audited proxy tunnel.

**Components, wired together by `setup.sh`:**

- **x11vnc** — grabs the real X11 display and serves it as VNC on
  `127.0.0.1:5900` (`-localhost`, never bound to a real network interface).
  Launched by `/usr/local/bin/x11vnc-start.sh`, which picks the session that
  is on screen *now* and then `exec`s into x11vnc.
- **x11vnc-watcher** (`/usr/local/bin/x11vnc-watch.sh`) — a separate root
  unit that watches for the active session changing and restarts
  `x11vnc.service` once the new session has settled. This is what makes the
  share follow a user switch; see "User switching" below for why it is a
  separate unit and why it waits.
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
  asks `logind` which session is actually `active` on a real `Seat` (type
  `x11`/`wayland`, UID ≥ 1000), then looks up *that specific user's*
  display via `who` (matching their username against a `:N`-shaped TTY
  field). Not a guessed `:0`/`:1`/`:2` range, and not logind's own
  `Display` session property either — that came back empty for X11
  sessions on the GDM/logind version this was actually tested against;
  `who`'s utmp-based reporting proved reliable where it wasn't. Needed at
  all because fast user switching (not a logout) leaves the previous
  user's X server alive in the background on its own display — a fixed
  probe just finds *an* X server that answers, not necessarily the one
  actually on screen — and each new graphical login gets the next free
  display number anyway (`:3`, `:4`, ...), so a small hardcoded range runs
  out after a couple of switches.
- **Which Xauth cookie?** Scoped to that *specific* active session's UID —
  `/run/user/<uid>/gdm/Xauthority`, `/run/user/<uid>/.mutter-Xwaylandauth*`,
  then that user's own `~/.Xauthority` — never a blind glob across every
  user's runtime dir, which could otherwise pick a different, stale user's
  cookie.
- **What if the active user changes while x11vnc is already running?** A
  separate unit, `x11vnc-watcher.service`, notices and restarts
  `x11vnc.service` so the wrapper reattaches to the new session. The share
  follows a fast user switch on its own — roughly 10-25s of black screen
  across the switch, then it reattaches. No logout needed.

  The delay is the safety mechanism, not slack. See "User switching — why
  the delay exists" below before shortening it.

## User switching — why the delay exists

This took four iterations to get right, and the obvious implementation is
the broken one. Worth reading before changing any of it.

| version | approach | result |
|---|---|---|
| v1 | killed x11vnc the instant a switch was detected | GNOME broke |
| v2 | exited instead; systemd's cgroup teardown killed it | GNOME broke |
| v3 | never tore down at all | safe, but never followed a switch |
| **v4** | tears down, but only **after** the switch fully settles | safe **and** follows |

In v1 and v2 the switch *away* worked fine — the new user's screen appeared
correctly. What broke was switching **back** to the earlier user: GDM came
apart, and the desktop rendered but accepted no input.

The cause was **timing, not the teardown itself**. v4 performs the same
destructive act as v2 — `SIGTERM` to an x11vnc attached to a live session —
and nothing breaks. Only the moment it lands changed. The rule underneath
all of it:

> Touching the X server during a VT switch breaks it.
> Before and after are both fine.

v2 landed inside that window on *every* switch, and its own code shows why:
it exited not only on "the display changed" but also on "no active session
found" — and "no active session" is exactly what a machine looks like
mid-transition, with the greeter up or the new session still
authenticating. That branch fired dead-centre of the danger window every
single time.

**What v4 does differently** (all of it in `/usr/local/bin/x11vnc-watch.sh`):

- "no active session" resets the counter and waits — it never triggers a
  restart.
- `LockedHint=no` is required: the user has actually finished logging in or
  unlocking. This matters most when switching *back*, where the returning
  session is already `active` while its lock screen is still on screen.
- the target display must hold steady across 3 consecutive polls (~6s) and
  answer `xdpyinfo`.
- a **separate always-running unit** does the watching. The wrapper is
  `x11vnc.service`'s own main process, so it loses every variable each time
  the unit restarts — it structurally cannot enforce a delay across one.
  The watcher never restarts, so it can.
- a 20s cooldown after each restart prevents thrash on rapid switching.

Note what is *not* gating the switch-back path: that session's X server
never died, so `xdpyinfo` answers instantly and proves nothing, and
`LockedHint` flips the moment the password is accepted — not when mutter has
finished reacquiring DRM master. On that path `SETTLE_POLLS` is doing nearly
all the work. If switch-back ever regresses, raise it (10 ≈ 20s) before
concluding anything else.

The x11vnc flags are deliberately left alone (no `-repeat`, no
`-clear_all`). Those address a different theory — state left behind in the
X server by an abrupt kill — which the v4 result ruled out: if residue were
the cause, v4 would break exactly as v2 did, since v4 changed nothing about
*how* x11vnc dies.

**Why root, not the desktop user's own systemd `--user` instance:** this
used to run as `$DESKTOP_USER` (whoever `setup.sh` detected at install
time), which meant it could only ever attach to *that one account's* X
session — it lacks permission to read a different user's `~/.Xauthority`
(mode 600, owned by them). VS desktop users change constantly in normal
use, so this produced a real recurring bug: switch from `prod` to
`customer` at the desktop without re-running `setup.sh`, and Remote
Desktop shows a black/stale screen — the service is still faithfully
attached to `prod`'s backgrounded session, permission-blocked from
`customer`'s live one. Root bypasses that entirely (root can read any
user's Xauthority), so the logind-driven scan above finds whoever's
*actually* active, every time, regardless of who was logged in when
`setup.sh` last ran. No re-install needed when the desktop user changes —
this is the one thing in the whole setup designed to self-heal on its own.

One more X11-specific wrinkle root doesn't get a pass on: MIT-SHM (the
shared-memory framebuffer extension x11vnc prefers for speed) is gated by
the X server on matching UID, not just a valid Xauth cookie — root gets a
hard `BadAccess` on `X_ShmAttach` even with the right cookie. `x11vnc` runs
with `-noshm` here (plain `XGetImage` polling) specifically because of
that — slower, but SHM literally cannot work across UIDs at all, so it's
not a tunable trade-off, it's the only way this works cross-user.

**Hardening / conflicts handled:**

- **`gnome-remote-desktop`** ships enabled by default on GNOME and also
  wants port 5900 — `setup.sh` deliberately does **not** touch it at all,
  neither `disable`/`mask`-ing the unit nor `pkill`-ing the running
  process by name. Both were tried and both caused real damage: masking
  broke GDM's own display-switch handling outright (`GDM_IS_REMOTE_DISPLAY`
  assertion failures on every switch, cascading into `gnome-shell`
  crashes); `pkill`-ing it by name was still enough on its own to
  reproduce the same class of breakage on a later switch, even with the
  unit correctly unmasked — confirmed by a clean A/B test (uninstalled →
  switching worked fine; re-ran `setup.sh` → broke again on the very next
  switch). If it's actually holding port 5900, the `fuser` port-clear
  further down handles that surgically, on the one port that matters,
  instead of broadly targeting a GNOME session process by name.
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
  (compatibility-layer) windows, not the compositor's real desktop. Worse,
  it fails *silently*: `who` reports a tty rather than a `:N` display for a
  Wayland session, so the wrapper never finds a display to attach to and
  retries forever with no error. The installer therefore sets
  `WaylandEnable=false` in `/etc/gdm3/custom.conf` — machine-wide, covering
  every account including ones created later. A per-user AccountsService
  `Session=ubuntu-xorg` is also written for the detected desktop user, but
  that alone is not enough on a multi-user VS: it only covers whoever
  happened to be at the seat during install, and the *next* user to log in
  would get Ubuntu's Wayland default. Both take effect at the next
  login/reboot — no `gdm` restart is issued, since that would kick off
  whoever is currently logged in.

## Prerequisites

- Ubuntu 22.04 or 24.04, GNOME desktop, an active local graphical login.
  Sessions must be **X11**, not Wayland — the installer enforces this
  itself (`WaylandEnable=false` at GDM, machine-wide), but it only takes
  effect at the next login/reboot. If the session running during install is
  Wayland, the share will not work until the machine is rebooted; the
  installer prints a `REBOOT REQUIRED` warning in that case.
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
cached identity), the systemd drop-in dir, the pid file, and both x11vnc
units plus their wrapper scripts. Guarantees the installer always works
cleanly afterward, including rejoining a cluster with a brand-new CA. (An
earlier lighter `--rejoin` mode was deliberately dropped — a VS should never
carry forward stale CA state.)

The **watcher is stopped first, before x11vnc** — that ordering is
load-bearing. Its job is `systemctl restart x11vnc`, so stopping x11vnc
while the watcher is still alive lets it start x11vnc again seconds later,
mid-uninstall, leaving an orphaned process holding port 5900 after the
script reports success.

Two things are deliberately **not** reverted, and the script says so on
exit:

- `WaylandEnable=false` in `/etc/gdm3/custom.conf` — indistinguishable from
  a line an admin set themselves, and silently flipping a machine back to
  Wayland during an uninstall is a bigger surprise than leaving it on Xorg.
  Revert by hand if wanted:
  `sudo sed -i 's/^WaylandEnable=false/#WaylandEnable=false/' /etc/gdm3/custom.conf`
- `psmisc` — pulled in for `fuser`, but a general-purpose package other
  things expect.

The per-user AccountsService Xorg pin *is* reverted, but only for lines
whose value is one of the Xorg sessions the installer actually sets, so a
deliberate admin choice is left alone.

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
- **`gnome-remote-desktop` conflicts on port 5900**: `setup.sh` doesn't
  touch it at all now — neither masking the unit nor `pkill`-ing the
  process, both caused the same GDM display-switch corruption on this
  Ubuntu/GNOME version (see "Hardening" above), confirmed by a clean
  before/after `uninstall.sh`/`setup.sh` test. A real,
  reboot-and-lose-the-session-level regression to avoid repeating — let
  the `fuser` port-clear handle any actual conflict instead.
- **Remote Desktop shows a black screen after the desktop user changes**:
  fixed by moving x11vnc/websockify off per-user `systemctl --user` onto
  root-run system services (see "Why root..." above) — was a real,
  recurring bug when this ran as whichever single account was detected at
  install time.
- **Black screen after switching users**: expected for ~10-25s while the
  new session settles, then it reattaches. If it stays black, reload the
  Teleport app tab first — the browser client does not always reconnect by
  itself after x11vnc restarts. If it is still black, check
  `journalctl -u x11vnc -u x11vnc-watcher -f`; the watcher logs the display
  it is waiting on and why it has not acted.
- **Share never attaches at all, watcher log repeats "No usable active
  graphical session yet"**: the session is Wayland. `who` reports a tty
  instead of a `:N` display, so there is nothing for x11vnc to attach to.
  Confirm with `loginctl show-session <id> -p Type --value`; fix by
  rebooting after the installer has set `WaylandEnable=false`.
- **GDM breaks when switching back to a previous user**: this is the v1/v2
  failure. Confirm which installer is deployed —
  `grep -c "exec /usr/bin/x11vnc" /usr/local/bin/x11vnc-start.sh` returns 1
  for v3/v4, 0 for v1/v2 — and check `x11vnc-watcher.service` exists. If
  the fleet was baked from `setup.sh` rather than `setup-v4.sh`, it is
  running v1 (see "Which script to deploy").
- **Package version drift across Ubuntu releases**: `novnc` is
  `1:1.0.0-5` on 22.04 vs `1:1.3.0-2` on 24.04 (confirmed different) —
  versions are pinned per-release in the script rather than left to apt's
  resolution.

