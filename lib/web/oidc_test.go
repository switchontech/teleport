/*
 * Teleport
 * Copyright (C) 2025  Gravitational, Inc.
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
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"github.com/gravitational/trace"
	"github.com/julienschmidt/httprouter"
	"github.com/stretchr/testify/require"

	"github.com/gravitational/teleport/api/types"
	"github.com/gravitational/teleport/lib/auth"
	"github.com/gravitational/teleport/lib/auth/authclient"
	"github.com/gravitational/teleport/lib/client"
	"github.com/gravitational/teleport/lib/httplib/csrf"
)

// fakeOIDCAuthClient is a minimal authclient.ClientI stand-in that only
// implements the three methods the OIDC proxy handlers depend on
// (CreateOIDCAuthRequest, ValidateOIDCAuthCallback, GetOIDCAuthRequest).
// This lets the handlers be tested without any real (or Enterprise-gated)
// OIDCService implementation.
type fakeOIDCAuthClient struct {
	authclient.ClientI

	createReq  *types.OIDCAuthRequest
	createErr  error
	gotCreated types.OIDCAuthRequest

	validateResp *authclient.OIDCAuthResponse
	validateErr  error

	getReq *types.OIDCAuthRequest
	getErr error
}

func (f *fakeOIDCAuthClient) CreateOIDCAuthRequest(ctx context.Context, req types.OIDCAuthRequest) (*types.OIDCAuthRequest, error) {
	f.gotCreated = req
	if f.createErr != nil {
		return nil, f.createErr
	}
	return f.createReq, nil
}

func (f *fakeOIDCAuthClient) ValidateOIDCAuthCallback(ctx context.Context, q url.Values) (*authclient.OIDCAuthResponse, error) {
	if f.validateErr != nil {
		return nil, f.validateErr
	}
	return f.validateResp, nil
}

func (f *fakeOIDCAuthClient) GetOIDCAuthRequest(ctx context.Context, id string) (*types.OIDCAuthRequest, error) {
	if f.getErr != nil {
		return nil, f.getErr
	}
	return f.getReq, nil
}

func newOIDCTestHandler(clt authclient.ClientI) *Handler {
	return &Handler{
		cfg:    Config{ProxyClient: clt},
		logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
}

// newCSRFCookieToken returns a valid-format CSRF token and a matching cookie
// to attach to a request, so that csrf.ExtractTokenFromCookie/VerifyToken
// succeed in tests.
func newCSRFCookieToken(t *testing.T) (token string, cookie *http.Cookie) {
	t.Helper()
	raw := bytes.Repeat([]byte{0x42}, 32)
	token = hex.EncodeToString(raw)
	return token, &http.Cookie{Name: csrf.CookieName, Value: token}
}

func TestOIDCLoginWeb(t *testing.T) {
	t.Run("success redirects to provider URL", func(t *testing.T) {
		token, cookie := newCSRFCookieToken(t)
		fake := &fakeOIDCAuthClient{
			createReq: &types.OIDCAuthRequest{RedirectURL: "https://accounts.google.com/o/oauth2/auth?foo=bar"},
		}
		h := newOIDCTestHandler(fake)

		u := &url.URL{Path: "/webapi/oidc/login/web", RawQuery: url.Values{
			"connector_id": {"google"},
			"redirect_url": {"/web/cluster/foo/nodes"},
		}.Encode()}
		r := httptest.NewRequest(http.MethodGet, u.String(), nil)
		r.AddCookie(cookie)
		r.RemoteAddr = "1.2.3.4:5678"
		w := httptest.NewRecorder()

		got := h.oidcLoginWeb(w, r, httprouter.Params{})
		require.Equal(t, "https://accounts.google.com/o/oauth2/auth?foo=bar", got)
		require.Equal(t, "google", fake.gotCreated.ConnectorID)
		require.True(t, fake.gotCreated.CreateWebSession)
		require.Equal(t, token, fake.gotCreated.CSRFToken)
	})

	t.Run("missing redirect_url fails closed", func(t *testing.T) {
		fake := &fakeOIDCAuthClient{}
		h := newOIDCTestHandler(fake)

		u := &url.URL{Path: "/webapi/oidc/login/web", RawQuery: url.Values{
			"connector_id": {"google"},
		}.Encode()}
		r := httptest.NewRequest(http.MethodGet, u.String(), nil)
		r.RemoteAddr = "1.2.3.4:5678"
		w := httptest.NewRecorder()

		got := h.oidcLoginWeb(w, r, httprouter.Params{})
		require.Equal(t, client.LoginFailedRedirectURL, got)
	})

	t.Run("auth request creation error fails closed", func(t *testing.T) {
		_, cookie := newCSRFCookieToken(t)
		fake := &fakeOIDCAuthClient{createErr: trace.AccessDenied("OIDC is not available")}
		h := newOIDCTestHandler(fake)

		u := &url.URL{Path: "/webapi/oidc/login/web", RawQuery: url.Values{
			"connector_id": {"google"},
			"redirect_url": {"/web"},
		}.Encode()}
		r := httptest.NewRequest(http.MethodGet, u.String(), nil)
		r.AddCookie(cookie)
		r.RemoteAddr = "1.2.3.4:5678"
		w := httptest.NewRecorder()

		got := h.oidcLoginWeb(w, r, httprouter.Params{})
		require.Equal(t, client.LoginFailedRedirectURL, got)
	})
}

func TestOIDCLoginConsole(t *testing.T) {
	t.Run("success returns redirect URL", func(t *testing.T) {
		fake := &fakeOIDCAuthClient{
			createReq: &types.OIDCAuthRequest{RedirectURL: "https://accounts.google.com/o/oauth2/auth?foo=bar"},
		}
		h := newOIDCTestHandler(fake)

		body, err := json.Marshal(client.SSOLoginConsoleReq{
			RedirectURL: "http://127.0.0.1:0/callback?secret_key=abc",
			ConnectorID: "google",
			CertTTL:     time.Hour,
			UserPublicKeys: client.UserPublicKeys{
				SSHPubKey: []byte("ssh-ed25519 AAAA fake"),
			},
		})
		require.NoError(t, err)

		r := httptest.NewRequest(http.MethodPost, "/webapi/oidc/login/console", bytes.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		r.RemoteAddr = "1.2.3.4:5678"
		w := httptest.NewRecorder()

		resp, err := h.oidcLoginConsole(w, r, httprouter.Params{})
		require.NoError(t, err)
		consoleResp, ok := resp.(*client.SSOLoginConsoleResponse)
		require.True(t, ok)
		require.Equal(t, "https://accounts.google.com/o/oauth2/auth?foo=bar", consoleResp.RedirectURL)
		require.Equal(t, "google", fake.gotCreated.ConnectorID)
	})

	t.Run("CheckAndSetDefaults failure yields generic error", func(t *testing.T) {
		fake := &fakeOIDCAuthClient{}
		h := newOIDCTestHandler(fake)

		// Missing ConnectorID.
		body, err := json.Marshal(client.SSOLoginConsoleReq{
			RedirectURL: "http://127.0.0.1:0/callback?secret_key=abc",
			CertTTL:     time.Hour,
		})
		require.NoError(t, err)

		r := httptest.NewRequest(http.MethodPost, "/webapi/oidc/login/console", bytes.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		r.RemoteAddr = "1.2.3.4:5678"
		w := httptest.NewRecorder()

		_, err = h.oidcLoginConsole(w, r, httprouter.Params{})
		require.True(t, trace.IsAccessDenied(err))
		require.Contains(t, err.Error(), SSOLoginFailureMessage)
	})

	t.Run("invalid client redirect maps to specific error", func(t *testing.T) {
		fake := &fakeOIDCAuthClient{
			createErr: trace.Wrap(trace.BadParameter("bad redirect"), auth.InvalidClientRedirectErrorMessage),
		}
		h := newOIDCTestHandler(fake)

		body, err := json.Marshal(client.SSOLoginConsoleReq{
			RedirectURL: "https://evil.example.com/callback?secret_key=abc",
			ConnectorID: "google",
			CertTTL:     time.Hour,
			UserPublicKeys: client.UserPublicKeys{
				SSHPubKey: []byte("ssh-ed25519 AAAA fake"),
			},
		})
		require.NoError(t, err)

		r := httptest.NewRequest(http.MethodPost, "/webapi/oidc/login/console", bytes.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		r.RemoteAddr = "1.2.3.4:5678"
		w := httptest.NewRecorder()

		_, err = h.oidcLoginConsole(w, r, httprouter.Params{})
		require.True(t, trace.IsAccessDenied(err))
		require.Contains(t, err.Error(), SSOLoginFailureInvalidRedirect)
	})
}

func TestOIDCCallback(t *testing.T) {
	t.Run("failure with known non-web state redirects to client redirect URL with error", func(t *testing.T) {
		wantErr := trace.AccessDenied("hosted domain mismatch")
		fake := &fakeOIDCAuthClient{
			validateErr: wantErr,
			getReq: &types.OIDCAuthRequest{
				CreateWebSession:  false,
				ClientRedirectURL: "http://127.0.0.1:0/callback?secret_key=abc",
			},
		}
		h := newOIDCTestHandler(fake)

		r := httptest.NewRequest(http.MethodGet, "/webapi/oidc/callback?state=abc123&code=xyz", nil)
		w := httptest.NewRecorder()

		got := h.oidcCallback(w, r, httprouter.Params{})

		u, err := url.Parse(got)
		require.NoError(t, err)
		require.Equal(t, wantErr.Error(), u.Query().Get("err"))
	})

	t.Run("failure with unknown state falls back to bad callback URL", func(t *testing.T) {
		fake := &fakeOIDCAuthClient{
			validateErr: trace.AccessDenied("boom"),
			getErr:      trace.NotFound("request not found"),
		}
		h := newOIDCTestHandler(fake)

		r := httptest.NewRequest(http.MethodGet, "/webapi/oidc/callback?state=missing&code=xyz", nil)
		w := httptest.NewRecorder()

		got := h.oidcCallback(w, r, httprouter.Params{})
		require.Equal(t, client.LoginFailedBadCallbackRedirectURL, got)
	})

	t.Run("success sets web session and redirects to client URL", func(t *testing.T) {
		token, cookie := newCSRFCookieToken(t)

		session, err := types.NewWebSession("session-id", types.KindWebSession, types.WebSessionSpecV2{
			User:               "alice@example.com",
			Pub:                []byte("not-a-real-cert"),
			BearerToken:        "bearer-token",
			BearerTokenExpires: time.Now().Add(time.Hour),
			Expires:            time.Now().Add(time.Hour),
		})
		require.NoError(t, err)

		fake := &fakeOIDCAuthClient{
			validateResp: &authclient.OIDCAuthResponse{
				Username: "alice@example.com",
				Session:  session,
				Req: authclient.OIDCAuthRequest{
					CSRFToken:         token,
					CreateWebSession:  true,
					ClientRedirectURL: "/web/cluster/foo/nodes",
				},
			},
		}
		h := newOIDCTestHandler(fake)

		r := httptest.NewRequest(http.MethodGet, "/webapi/oidc/callback?state=abc123&code=xyz", nil)
		r.AddCookie(cookie)
		w := httptest.NewRecorder()

		got := h.oidcCallback(w, r, httprouter.Params{})
		require.Equal(t, "/web/cluster/foo/nodes", got)

		// A session cookie should have been set.
		resp := w.Result()
		var found bool
		for _, c := range resp.Cookies() {
			if c.Name != "" {
				found = true
			}
		}
		require.True(t, found, "expected a session cookie to be set")
	})
}
