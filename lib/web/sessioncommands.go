/*
 * Teleport
 * Copyright (C) 2026  Gravitational, Inc.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

package web

import (
	"context"
	"net/http"
	"strings"
	"time"

	"github.com/gravitational/trace"
	"github.com/julienschmidt/httprouter"

	"github.com/gravitational/teleport/api/types"
	apievents "github.com/gravitational/teleport/api/types/events"
	"github.com/gravitational/teleport/lib/auth/authclient"
	"github.com/gravitational/teleport/lib/defaults"
	"github.com/gravitational/teleport/lib/events"
	"github.com/gravitational/teleport/lib/reversetunnelclient"
	"github.com/gravitational/teleport/lib/session"
)

// commandSearchWindowPadding widens the [session start, session end) time
// range used to search the audit log for session.command events, to absorb
// clock skew between the node emitting BPF events and the auth server.
const commandSearchWindowPadding = 5 * time.Second

// sessionCommandEntry is a single command executed within a session, as
// reported by enhanced session recording (BPF).
type sessionCommandEntry struct {
	// OffsetMs is the number of milliseconds from session start to when the
	// command ran, computed against the full-precision session start time
	// (avoids the seconds-only precision of the recording metadata's
	// startTime, which would otherwise desync playback seeking).
	OffsetMs   int64    `json:"offsetMs"`
	Path       string   `json:"path"`
	Argv       []string `json:"argv"`
	Cmd        string   `json:"cmd"`
	ReturnCode int32    `json:"returnCode"`
	PID        uint64   `json:"pid"`
	PPID       uint64   `json:"ppid"`
}

// sessionCommandsResponse is the response body for getSessionCommands.
type sessionCommandsResponse struct {
	Commands []sessionCommandEntry `json:"commands"`
	// EnhancedRecordingEnabled reports whether the session actually had
	// enhanced (BPF) recording turned on, so the frontend can tell "no
	// commands ran" apart from "this session can't record commands".
	EnhancedRecordingEnabled bool `json:"enhancedRecordingEnabled"`
}

// getSessionCommands returns the list of commands (session.command audit
// events) executed during an SSH session, in chronological order, with each
// command's offset (in milliseconds) from the start of the session.
//
// Enhanced session recording (BPF) events are emitted straight to the audit
// log by the node and are never written into the session recording stream
// itself (see ServerContext.BPFEmitter), so they must be fetched via
// SearchEvents rather than StreamSessionEvents.
//
// GET /v1/webapi/sites/:site/sessions/:session_id/commands
func (h *Handler) getSessionCommands(
	w http.ResponseWriter,
	r *http.Request,
	p httprouter.Params,
	sctx *SessionContext,
	cluster reversetunnelclient.Cluster,
) (any, error) {
	sessionID := p.ByName("session_id")
	if sessionID == "" {
		return nil, trace.BadParameter("missing session_id in request URL")
	}

	ctx := r.Context()
	clt, err := sctx.GetUserClient(ctx, cluster)
	if err != nil {
		return nil, trace.Wrap(err)
	}

	startTime, endTime, enhancedRecordingEnabled, err := findSessionBounds(ctx, clt, sessionID)
	if err != nil {
		return nil, trace.Wrap(err)
	}

	if endTime.IsZero() {
		endTime = time.Now().UTC()
	}

	commands, err := searchSessionCommands(ctx, clt, sessionID, startTime, endTime)
	if err != nil {
		return nil, trace.Wrap(err)
	}

	return sessionCommandsResponse{
		Commands:                 commands,
		EnhancedRecordingEnabled: enhancedRecordingEnabled,
	}, nil
}

// findSessionBounds streams the session recording to find the session's
// start/end time and whether enhanced recording was active, without pulling
// the (potentially large) PTY data through.
func findSessionBounds(ctx context.Context, clt authclient.ClientI, sessionID string) (startTime, endTime time.Time, enhancedRecordingEnabled bool, err error) {
	evts, errs := clt.StreamSessionEvents(ctx, session.ID(sessionID), 0)

	for {
		select {
		case err := <-errs:
			if err != nil {
				return time.Time{}, time.Time{}, false, trace.Wrap(err)
			}
		case evt, ok := <-evts:
			if !ok {
				return startTime, endTime, enhancedRecordingEnabled, nil
			}

			switch e := evt.(type) {
			case *apievents.SessionStart:
				startTime = e.Time
			case *apievents.SessionEnd:
				endTime = e.Time
				enhancedRecordingEnabled = e.EnhancedRecording
			}
		}
	}
}

// searchSessionCommands searches the audit log for session.command events
// belonging to sessionID within [from, to], paginating until exhausted.
// Shell startup/teardown helper invocations (rc-file sourcing, PAM checks,
// logout cleanup) are filtered out so only commands a person actually typed
// are returned.
func searchSessionCommands(ctx context.Context, clt authclient.ClientI, sessionID string, from, to time.Time) ([]sessionCommandEntry, error) {
	from = from.Add(-commandSearchWindowPadding)
	to = to.Add(commandSearchWindowPadding)

	var (
		commands []sessionCommandEntry
		startKey string
	)

	for {
		rawEvents, lastKey, err := clt.SearchEvents(ctx, events.SearchEventsRequest{
			From:       from,
			To:         to,
			EventTypes: []string{events.SessionCommandEvent},
			Limit:      defaults.EventsIterationLimit,
			Order:      types.EventOrderAscending,
			StartKey:   startKey,
		})
		if err != nil {
			return nil, trace.Wrap(err)
		}

		for _, raw := range rawEvents {
			cmd, ok := raw.(*apievents.SessionCommand)
			if !ok || cmd.SessionID != sessionID {
				continue
			}

			cmdStr := strings.TrimSpace(strings.Join(append([]string{cmd.Path}, cmd.Argv...), " "))
			if isShellStartupNoise(cmd.Path, cmdStr) {
				continue
			}

			commands = append(commands, sessionCommandEntry{
				OffsetMs:   offsetMillis(cmd.Time, from.Add(commandSearchWindowPadding)),
				Path:       cmd.Path,
				Argv:       cmd.Argv,
				Cmd:        cmdStr,
				ReturnCode: cmd.ReturnCode,
				PID:        cmd.PID,
				PPID:       cmd.PPID,
			})
		}

		if lastKey == "" || len(commands) >= defaults.EventsMaxIterationLimit {
			break
		}
		startKey = lastKey
	}

	return commands, nil
}

// shellStartupNoiseCommands are exact (path + args) invocations that
// interactive bash startup/teardown triggers on most Linux distros (sourcing
// ~/.bashrc, PAM homedir checks, lesspipe/dircolors setup, logout cleanup).
// BPF enhanced recording captures these execve calls alongside real user
// commands since it traces at the syscall level, not the keystroke level.
var shellStartupNoiseCommands = map[string]bool{
	"/bin/bash":                           true,
	"/proc/self/exe checkhomedir":         true,
	"/usr/bin/uname -m":                   true,
	"/usr/bin/lesspipe":                   true,
	"/usr/bin/basename /usr/bin/lesspipe": true,
	"/usr/bin/dirname /usr/bin/lesspipe":  true,
	"/usr/bin/dircolors -b":               true,
	"/usr/bin/clear_console -q":           true,
}

// shellStartupNoisePaths matches noise commands whose args vary (so an exact
// string match in shellStartupNoiseCommands won't catch them), keyed by the
// executable path.
var shellStartupNoisePaths = map[string]bool{
	"/usr/bin/locale-check": true,
}

func isShellStartupNoise(path, cmdStr string) bool {
	return shellStartupNoiseCommands[cmdStr] || shellStartupNoisePaths[path]
}

func offsetMillis(t, sessionStart time.Time) int64 {
	offsetMs := t.Sub(sessionStart).Milliseconds()
	if offsetMs < 0 {
		return 0
	}
	return offsetMs
}
