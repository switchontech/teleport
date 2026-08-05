// ssh-access-watcher watches Teleport node registrations and keeps the
// "ssh-access" role's logins list up to date automatically: whenever a VS
// registers with a "vs-user" label that isn't already an allowed login,
// this appends it and re-applies the role. No human step required when a
// new VS joins.
//
// Runs as its own long-lived process, authenticated with a dedicated,
// narrowly-scoped machine identity (see roles/ssh-access-watcher.yaml) —
// not a human account, no elevated permissions beyond reading nodes and
// updating this one role.
package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"slices"
	"syscall"
	"time"

	"github.com/gravitational/teleport/api/client"
	"github.com/gravitational/teleport/api/types"
	"sigs.k8s.io/yaml"
)

const (
	roleName    = "ssh-access"
	vsUserLabel = "vs-user"
)

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stdout, nil))

	proxyAddr := os.Getenv("TELEPORT_PROXY_ADDR")
	if proxyAddr == "" {
		logger.Error("TELEPORT_PROXY_ADDR is not set")
		os.Exit(1)
	}
	identityPath := os.Getenv("TELEPORT_IDENTITY_FILE")
	if identityPath == "" {
		identityPath = "secrets/identity"
	}
	// Optional: also mirror the updated role to this YAML file, so the
	// git-tracked source doesn't drift from the live cluster. Skipped if
	// unset — the watcher still updates the live role either way.
	roleFilePath := os.Getenv("SSH_ACCESS_ROLE_FILE")

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Reconnect indefinitely on any failure. This process has no external
	// supervisor watching it (systemd/docker only restarts on the whole
	// process exiting) — a broken loop that just returns leaves the
	// automation silently dead until someone notices, so it must retry
	// internally rather than give up.
	backoff := time.Second
	const maxBackoff = 30 * time.Second

	for {
		err := run(ctx, logger, proxyAddr, identityPath, roleFilePath)
		if ctx.Err() != nil {
			logger.Info("shutting down")
			return
		}

		logger.Error("watch loop exited, retrying", "error", err, "retry_in", backoff)
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		if backoff < maxBackoff {
			backoff *= 2
		}
	}
}

func run(ctx context.Context, logger *slog.Logger, proxyAddr, identityPath, roleFilePath string) error {
	clt, err := client.New(ctx, client.Config{
		Addrs:       []string{proxyAddr},
		Credentials: []client.Credentials{client.LoadIdentityFile(identityPath)},
	})
	if err != nil {
		return err
	}
	defer clt.Close()

	watcher, err := clt.NewWatcher(ctx, types.Watch{
		Name:  "ssh-access-watcher",
		Kinds: []types.WatchKind{{Kind: types.KindNode}},
	})
	if err != nil {
		return err
	}
	defer watcher.Close()

	logger.Info("watcher connected, waiting for node events")

	for {
		select {
		case <-ctx.Done():
			return nil
		case <-watcher.Done():
			return watcher.Error()
		case event := <-watcher.Events():
			handleEvent(ctx, logger, clt, event, roleFilePath)
		}
	}
}

func handleEvent(ctx context.Context, logger *slog.Logger, clt *client.Client, event types.Event, roleFilePath string) {
	if event.Type != types.OpPut {
		return
	}

	node, ok := event.Resource.(types.Server)
	if !ok {
		return
	}

	vsUser := node.GetAllLabels()[vsUserLabel]
	if vsUser == "" {
		return
	}

	role, err := clt.GetRole(ctx, roleName)
	if err != nil {
		logger.Error("failed to fetch role", "role", roleName, "error", err)
		return
	}

	logins := role.GetLogins(types.Allow)
	if slices.Contains(logins, vsUser) {
		logger.Debug("login already present, nothing to do", "node", node.GetName(), "login", vsUser)
		return
	}

	role.SetLogins(types.Allow, append(logins, vsUser))
	updated, err := clt.UpsertRole(ctx, role)
	if err != nil {
		logger.Error("failed to update role", "role", roleName, "login", vsUser, "error", err)
		return
	}

	logger.Info("added new VS login to ssh-access", "node", node.GetName(), "login", vsUser)

	if roleFilePath == "" {
		return
	}
	if err := writeRoleFile(roleFilePath, updated); err != nil {
		// The live role is already updated at this point — a failure here
		// means the tracked file drifts, not that access is broken. Log
		// loudly but don't treat it as fatal to the watch loop.
		logger.Error("failed to write role file", "path", roleFilePath, "error", err)
		return
	}
	logger.Info("updated role file", "path", roleFilePath)
}

// writeRoleFile mirrors role to roleFilePath as YAML, in the same shape
// "tctl create -f" expects. Written atomically (temp file + rename) so a
// crash or concurrent read never sees a half-written file.
func writeRoleFile(roleFilePath string, role types.Role) error {
	// Role's JSON tags already match Teleport's config-file field names
	// (kind, version, metadata, spec, ...), so JSON->YAML conversion gives
	// the correct shape without needing Teleport's own (much heavier)
	// internal marshaling helpers.
	jsonBytes, err := json.Marshal(role)
	if err != nil {
		return err
	}
	yamlBytes, err := yaml.JSONToYAML(jsonBytes)
	if err != nil {
		return err
	}

	// This process runs as root, but the file belongs to a human-owned repo
	// checkout — preserve whoever already owns it (and its mode) rather
	// than silently handing it to root, which would lock the human out of
	// their own working copy. Only applies if the file already exists;
	// a first-ever write just gets root's own default ownership.
	uid, gid, mode := os.Getuid(), os.Getgid(), os.FileMode(0o644)
	if existing, err := os.Stat(roleFilePath); err == nil {
		mode = existing.Mode()
		if st, ok := existing.Sys().(*syscall.Stat_t); ok {
			uid, gid = int(st.Uid), int(st.Gid)
		}
	}

	dir := filepath.Dir(roleFilePath)
	tmp, err := os.CreateTemp(dir, ".ssh-access-*.yaml.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath) // no-op once the rename below succeeds

	if _, err := tmp.Write(yamlBytes); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chown(tmpPath, uid, gid); err != nil {
		return err
	}
	if err := os.Chmod(tmpPath, mode); err != nil {
		return err
	}
	return os.Rename(tmpPath, roleFilePath)
}
