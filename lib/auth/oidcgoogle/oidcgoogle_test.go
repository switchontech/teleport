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

package oidcgoogle

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/gravitational/trace"
	"github.com/stretchr/testify/require"

	"github.com/gravitational/teleport/api/types"
	apievents "github.com/gravitational/teleport/api/types/events"
	"github.com/gravitational/teleport/lib/events"
)

// ---------------------------------------------------------------------------
// Constructor
// ---------------------------------------------------------------------------

func TestNewFailsClosedWithoutHostedDomain(t *testing.T) {
	t.Parallel()

	identity := newFakeIdentity()

	for _, tc := range []struct {
		name         string
		hostedDomain string
		assertErr    require.ErrorAssertionFunc
	}{
		{
			// The whole point: with no hosted domain there is no way to tell a
			// corporate account from a personal Gmail account.
			name:         "empty is refused",
			hostedDomain: "",
			assertErr:    require.Error,
		},
		{
			name:         "non-ascii is refused",
			hostedDomain: "exàmple.com",
			assertErr:    require.Error,
		},
		{
			name:         "not a domain is refused",
			hostedDomain: "example",
			assertErr:    require.Error,
		},
		{
			name:         "url is refused",
			hostedDomain: "https://example.com",
			assertErr:    require.Error,
		},
		{
			name:         "valid",
			hostedDomain: "example.com",
			assertErr:    require.NoError,
		},
		{
			name:         "valid, normalised to lower case",
			hostedDomain: "Example.COM",
			assertErr:    require.NoError,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			svc, err := New(Config{
				HostedDomain: tc.hostedDomain,
				Identity:     identity,
				Auth:         nopAuthService{},
			})
			tc.assertErr(t, err)
			if err == nil {
				require.Equal(t, strings.ToLower(tc.hostedDomain), svc.hostedDomain)
			}
		})
	}
}

func TestNewRequiresDependencies(t *testing.T) {
	t.Parallel()

	_, err := New(Config{HostedDomain: testHostedDomain, Auth: nopAuthService{}})
	require.Error(t, err)

	_, err = New(Config{HostedDomain: testHostedDomain, Identity: newFakeIdentity()})
	require.Error(t, err)
}

// ---------------------------------------------------------------------------
// Nonce derivation
// ---------------------------------------------------------------------------

func TestNonceForStateToken(t *testing.T) {
	t.Parallel()

	// The binding rule every slice must agree on: nonce = hex(SHA-256(state)).
	const state = "0123456789abcdef"
	sum := sha256.Sum256([]byte(state))
	require.Equal(t, hex.EncodeToString(sum[:]), NonceForStateToken(state))
	require.Len(t, NonceForStateToken(state), 64)
	require.NotEqual(t, NonceForStateToken(state), NonceForStateToken(state+"0"))
}

// ---------------------------------------------------------------------------
// Request side
// ---------------------------------------------------------------------------

func TestCreateOIDCAuthRequest(t *testing.T) {
	t.Parallel()
	env := setupTestEnv(t)

	req := env.startLogin(t, types.OIDCAuthRequest{
		ConnectorID:       testConnectorID,
		ClientRedirectURL: "http://127.0.0.1:12345/callback?secret_key=abc",
		CertTTL:           time.Hour,
	})

	require.NotEmpty(t, req.StateToken)
	require.NotEmpty(t, req.PkceVerifier)
	// The request must be persisted, or the callback has nothing to look up.
	require.Equal(t, 1, env.identity.count())

	authURL, err := url.Parse(req.RedirectURL)
	require.NoError(t, err)
	q := authURL.Query()

	require.Equal(t, req.StateToken, q.Get("state"))
	require.Equal(t, NonceForStateToken(req.StateToken), q.Get("nonce"))
	require.Equal(t, "code", q.Get("response_type"))
	require.Equal(t, testClientID, q.Get("client_id"))
	require.Equal(t, testRedirectURL, q.Get("redirect_uri"))
	require.Equal(t, "openid email profile", q.Get("scope"))
	// PKCE is always on.
	require.Equal(t, "S256", q.Get("code_challenge_method"))
	require.NotEmpty(t, q.Get("code_challenge"))
	require.NotEqual(t, req.PkceVerifier, q.Get("code_challenge"))
	// "hd" on the authorization URL is a UI hint; it carries no security weight
	// but it should still be there so Google's account chooser behaves.
	require.Equal(t, testHostedDomain, q.Get("hd"))

	// The endpoint must have come from discovery, not a hardcoded google.com.
	require.True(t, strings.HasPrefix(req.RedirectURL, env.google.issuer()+"/authorize"),
		"authorization endpoint should come from OIDC discovery, got %q", req.RedirectURL)
}

func TestCreateOIDCAuthRequestStateIsUnpredictable(t *testing.T) {
	t.Parallel()
	env := setupTestEnv(t)

	seen := make(map[string]struct{})
	for range 20 {
		req := env.startLogin(t, types.OIDCAuthRequest{
			ClientRedirectURL: "http://127.0.0.1:12345/callback?secret_key=abc",
		})
		require.NotContains(t, seen, req.StateToken)
		seen[req.StateToken] = struct{}{}
	}
}

// TestCreateOIDCAuthRequestValidatesClientRedirect is the certificate-theft
// test. Without sso.ValidateClientRedirect, an attacker sends a victim a login
// link carrying the attacker's redirect_url; the victim completes a genuine
// Google login and the attacker's listener receives the victim's certificates.
func TestCreateOIDCAuthRequestValidatesClientRedirect(t *testing.T) {
	t.Parallel()
	env := setupTestEnv(t)
	ctx := context.Background()

	for _, tc := range []struct {
		name             string
		clientRedirect   string
		createWebSession bool
		ssoTestFlow      bool
		assertErr        require.ErrorAssertionFunc
	}{
		{
			name:           "loopback callback accepted",
			clientRedirect: "http://127.0.0.1:41234/callback?secret_key=abc",
			assertErr:      require.NoError,
		},
		{
			name:           "localhost callback accepted",
			clientRedirect: "http://localhost:41234/callback?secret_key=abc",
			assertErr:      require.NoError,
		},
		{
			name:           "evil host rejected",
			clientRedirect: "https://evil.example.net/callback?secret_key=abc",
			assertErr:      require.Error,
		},
		{
			name:           "evil host over http rejected",
			clientRedirect: "http://evil.example.net/callback?secret_key=abc",
			assertErr:      require.Error,
		},
		{
			name:           "non callback path rejected",
			clientRedirect: "http://127.0.0.1:41234/steal?secret_key=abc",
			assertErr:      require.Error,
		},
		{
			name:           "extra query params rejected",
			clientRedirect: "http://127.0.0.1:41234/callback?secret_key=abc&x=1",
			assertErr:      require.Error,
		},
		{
			// tctl sso test must not be a way around the rule.
			name:           "custom host rejected in test flow",
			clientRedirect: "https://evil.example.net/callback?secret_key=abc",
			ssoTestFlow:    true,
			assertErr:      require.Error,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			req := types.OIDCAuthRequest{
				ConnectorID:       testConnectorID,
				ClientRedirectURL: tc.clientRedirect,
				CreateWebSession:  tc.createWebSession,
				SSOTestFlow:       tc.ssoTestFlow,
			}
			if tc.ssoTestFlow {
				spec := env.connector.(*types.OIDCConnectorV3).Spec
				req.ConnectorSpec = &spec
			}
			_, err := env.svc.CreateOIDCAuthRequest(ctx, req)
			tc.assertErr(t, err)
		})
	}
}

// The web flow skips client redirect validation, exactly as GitHub's does: the
// request comes from the proxy, which sets the session cookie itself and
// redirects within its own UI. No certificate is handed to that URL.
func TestCreateOIDCAuthRequestWebSessionSkipsClientRedirectValidation(t *testing.T) {
	t.Parallel()
	env := setupTestEnv(t)

	_, err := env.svc.CreateOIDCAuthRequest(context.Background(), types.OIDCAuthRequest{
		ConnectorID:       testConnectorID,
		CreateWebSession:  true,
		ClientRedirectURL: "/web/cluster/me.localhost/nodes",
	})
	require.NoError(t, err)
}

// A caller-supplied connector spec on a real login would let anyone who can
// reach the auth API define their own IdP, client ID and role mapping.
func TestCreateOIDCAuthRequestRejectsConnectorSpecOutsideTestFlow(t *testing.T) {
	t.Parallel()
	env := setupTestEnv(t)

	spec := env.connector.(*types.OIDCConnectorV3).Spec
	_, err := env.svc.CreateOIDCAuthRequest(context.Background(), types.OIDCAuthRequest{
		ConnectorID:   testConnectorID,
		ConnectorSpec: &spec,
	})
	require.Error(t, err)
	require.True(t, trace.IsBadParameter(err), "expected BadParameter, got %v", err)
}

func TestCreateOIDCAuthRequestForMFANotImplemented(t *testing.T) {
	t.Parallel()
	env := setupTestEnv(t)

	_, err := env.svc.CreateOIDCAuthRequestForMFA(context.Background(), types.OIDCAuthRequest{
		ConnectorID: testConnectorID,
	})
	require.True(t, trace.IsNotImplemented(err), "expected NotImplemented, got %v", err)
}

// ---------------------------------------------------------------------------
// Connector policy
// ---------------------------------------------------------------------------

// Every case here is a setting we cannot enforce. Silently ignoring a control an
// administrator deliberately turned on is how security controls quietly stop
// working, so each one is a hard refusal.
func TestCheckConnectorFailsClosed(t *testing.T) {
	t.Parallel()
	env := setupTestEnv(t)

	for _, tc := range []struct {
		name    string
		mutate  func(spec *types.OIDCConnectorSpecV3)
		wantErr bool
	}{
		{name: "unmodified", mutate: func(*types.OIDCConnectorSpecV3) {}},
		{
			name:    "issuer is not google",
			mutate:  func(s *types.OIDCConnectorSpecV3) { s.IssuerURL = "https://login.microsoftonline.com/common/v2.0" },
			wantErr: true,
		},
		{
			name:    "allow_unverified_email",
			mutate:  func(s *types.OIDCConnectorSpecV3) { s.AllowUnverifiedEmail = true },
			wantErr: true,
		},
		{
			name:    "max_age",
			mutate:  func(s *types.OIDCConnectorSpecV3) { d := types.Duration(time.Hour); s.MaxAge = &types.MaxAge{Value: d} },
			wantErr: true,
		},
		{
			name:    "google directory sync",
			mutate:  func(s *types.OIDCConnectorSpecV3) { s.GoogleAdminEmail = "admin@example.com" },
			wantErr: true,
		},
		{
			name: "sso mfa",
			mutate: func(s *types.OIDCConnectorSpecV3) {
				s.MFASettings = &types.OIDCConnectorMFASettings{Enabled: true, ClientId: "x", ClientSecret: "y"}
			},
			wantErr: true,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			spec := env.connector.(*types.OIDCConnectorV3).Spec
			tc.mutate(&spec)
			connector, err := types.NewOIDCConnector(testConnectorID, spec)
			require.NoError(t, err)

			err = env.svc.checkConnector(connector)
			if tc.wantErr {
				require.Error(t, err)
			} else {
				require.NoError(t, err)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Callback side: the token table
// ---------------------------------------------------------------------------

func TestValidateOIDCAuthCallback(t *testing.T) {
	t.Parallel()

	for _, tc := range []struct {
		name string
		// opts describes the ID token the fake Google returns. nonce is filled
		// in from the real state token unless overrideNonce is set.
		opts          tokenOpts
		overrideNonce string
		wantErr       bool
		// wantUnauthorized asserts the error matches ErrUnauthorizedIdentity,
		// i.e. "you authenticated but you may not log in", as opposed to
		// "authentication itself failed".
		wantUnauthorized bool
		errContains      string
	}{
		{
			name: "valid",
		},
		{
			name:        "wrong audience",
			opts:        tokenOpts{audience: "someone-elses-client-id"},
			wantErr:     true,
			errContains: "verification failed",
		},
		{
			name:        "wrong issuer",
			opts:        tokenOpts{issuer: "https://accounts.evil.example.net"},
			wantErr:     true,
			errContains: "verification failed",
		},
		{
			name:        "expired",
			opts:        tokenOpts{expires: time.Now().Add(-time.Minute)},
			wantErr:     true,
			errContains: "verification failed",
		},
		{
			name:        "bad signature",
			opts:        tokenOpts{forgeSignature: true},
			wantErr:     true,
			errContains: "verification failed",
		},
		{
			name:          "nonce mismatch",
			overrideNonce: "not-the-nonce-for-this-state",
			wantErr:       true,
			errContains:   "verification failed",
		},
		{
			name:          "empty nonce",
			overrideNonce: " ",
			wantErr:       true,
			errContains:   "verification failed",
		},
		{
			// The single most important negative case. A personal Gmail
			// account carries no "hd" claim at all. If this were written as
			// "reject only when hd is present and wrong", every Gmail account
			// in the world would be admitted.
			name:             "no hosted domain (personal gmail)",
			opts:             tokenOpts{omitHostedDomain: true, email: "someone@gmail.com"},
			wantErr:          true,
			wantUnauthorized: true,
			errContains:      "no hosted domain",
		},
		{
			name:             "wrong hosted domain",
			opts:             tokenOpts{hostedDomain: "other.example.net"},
			wantErr:          true,
			wantUnauthorized: true,
			errContains:      "other.example.net",
		},
		{
			// The classic break: a naive suffix check on the email claim would
			// let this through. The email is not consulted for the domain.
			name: "email suffix lookalike does not substitute for hd",
			opts: tokenOpts{
				omitHostedDomain: true,
				email:            "attacker@" + testHostedDomain + ".evil.net",
			},
			wantErr:          true,
			wantUnauthorized: true,
			errContains:      "no hosted domain",
		},
		{
			name: "hosted domain lookalike in email with correct hd is fine",
			opts: tokenOpts{
				hostedDomain: testHostedDomain,
				email:        "bob@" + testHostedDomain,
			},
		},
		{
			name:             "email not verified",
			opts:             tokenOpts{emailVerified: false},
			wantErr:          true,
			wantUnauthorized: true,
			errContains:      "unverified",
		},
		{
			name:             "email_verified absent is treated as false",
			opts:             tokenOpts{emailVerified: ""},
			wantErr:          true,
			wantUnauthorized: true,
			errContains:      "unverified",
		},
		{
			name:        "no subject",
			opts:        tokenOpts{omitSubject: true},
			wantErr:     true,
			errContains: "verification failed",
		},
		{
			name: "hosted domain case is normalised",
			opts: tokenOpts{hostedDomain: "EXAMPLE.com"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			env := setupTestEnv(t)
			ctx := context.Background()

			req := env.startLogin(t, types.OIDCAuthRequest{
				ClientRedirectURL: "http://127.0.0.1:41234/callback?secret_key=abc",
				CertTTL:           time.Hour,
			})

			opts := tc.opts
			opts.nonce = NonceForStateToken(req.StateToken)
			if tc.overrideNonce != "" {
				opts.nonce = strings.TrimSpace(tc.overrideNonce)
			}
			env.google.setIDToken(env.google.issueToken(t, opts))

			resp, err := env.svc.ValidateOIDCAuthCallback(ctx, url.Values{
				"code":  []string{"auth-code"},
				"state": []string{req.StateToken},
			})

			if !tc.wantErr {
				require.NoError(t, err)
				require.NotNil(t, resp)
				require.Equal(t, testConnectorID, resp.Identity.ConnectorID)
				require.Equal(t, resp.Username, resp.Identity.Username)
				// Req must be the JSON-friendly authclient shape.
				require.Equal(t, testConnectorID, resp.Req.ConnectorID)
				requireLoginEvent(t, env, events.UserSSOLoginCode, "")
				return
			}

			require.Error(t, err)
			require.Nil(t, resp)
			if tc.errContains != "" {
				require.Contains(t, strings.ToLower(err.Error()), strings.ToLower(tc.errContains))
			}
			require.Equal(t, tc.wantUnauthorized, errors.Is(err, ErrUnauthorizedIdentity),
				"ErrUnauthorizedIdentity match mismatch for %v", err)

			// Every rejection must leave a UserLogin failure event carrying the
			// reason.
			requireLoginEvent(t, env, events.UserSSOLoginFailureCode, tc.errContains)
		})
	}
}

// requireLoginEvent asserts that the last emitted audit event is a UserLogin
// with the given code, and (for failures) that it records a reason.
func requireLoginEvent(t *testing.T, env *testEnv, code, reasonContains string) {
	t.Helper()

	last := env.emitter.LastEvent()
	require.NotNil(t, last, "expected a UserLogin audit event to be emitted")
	require.Equal(t, events.UserLoginEvent, last.GetType())
	require.Equal(t, code, last.GetCode())

	login, ok := last.(*apievents.UserLogin)
	require.True(t, ok, "expected *apievents.UserLogin, got %T", last)
	require.Equal(t, events.LoginMethodOIDC, login.Method)

	if code == events.UserSSOLoginCode || code == events.UserSSOTestFlowLoginCode {
		require.True(t, login.Status.Success)
		require.NotEmpty(t, login.User)
		return
	}

	require.False(t, login.Status.Success)
	require.NotEmpty(t, login.Status.Error, "failure event must record why the login was rejected")
	if reasonContains != "" {
		require.Contains(t,
			strings.ToLower(login.Status.Error+" "+login.Status.UserMessage),
			strings.ToLower(reasonContains))
	}
}

// ---------------------------------------------------------------------------
// State token handling
// ---------------------------------------------------------------------------

func TestValidateOIDCAuthCallbackStateIsSingleUse(t *testing.T) {
	t.Parallel()
	env := setupTestEnv(t)
	ctx := context.Background()

	req := env.startLogin(t, types.OIDCAuthRequest{
		ClientRedirectURL: "http://127.0.0.1:41234/callback?secret_key=abc",
		CertTTL:           time.Hour,
	})
	env.google.setIDToken(env.google.issueToken(t, tokenOpts{nonce: NonceForStateToken(req.StateToken)}))

	q := url.Values{"code": []string{"auth-code"}, "state": []string{req.StateToken}}

	_, err := env.svc.ValidateOIDCAuthCallback(ctx, q)
	require.NoError(t, err)
	require.Equal(t, 0, env.identity.count(), "the auth request must be deleted on use")

	// Replaying the same callback must fail.
	_, err = env.svc.ValidateOIDCAuthCallback(ctx, q)
	require.Error(t, err)
	require.True(t, trace.IsNotFound(err), "expected NotFound on replay, got %v", err)
	requireLoginEvent(t, env, events.UserSSOLoginFailureCode, "")
}

func TestValidateOIDCAuthCallbackUnknownState(t *testing.T) {
	t.Parallel()
	env := setupTestEnv(t)

	_, err := env.svc.ValidateOIDCAuthCallback(context.Background(), url.Values{
		"code":  []string{"auth-code"},
		"state": []string{"never-issued"},
	})
	require.Error(t, err)
	require.True(t, trace.IsNotFound(err), "expected NotFound, got %v", err)
}

func TestValidateOIDCAuthCallbackMissingState(t *testing.T) {
	t.Parallel()
	env := setupTestEnv(t)

	_, err := env.svc.ValidateOIDCAuthCallback(context.Background(), url.Values{
		"code": []string{"auth-code"},
	})
	require.Error(t, err)
	requireLoginEvent(t, env, events.UserSSOLoginFailureCode, "")
}

// If the state token cannot be consumed we must not proceed: leaving it in the
// backend would leave it replayable.
func TestValidateOIDCAuthCallbackFailsClosedIfStateCannotBeDeleted(t *testing.T) {
	t.Parallel()
	env := setupTestEnv(t)

	req := env.startLogin(t, types.OIDCAuthRequest{
		ClientRedirectURL: "http://127.0.0.1:41234/callback?secret_key=abc",
		CertTTL:           time.Hour,
	})
	env.google.setIDToken(env.google.issueToken(t, tokenOpts{nonce: NonceForStateToken(req.StateToken)}))
	env.identity.deleteErr = trace.ConnectionProblem(nil, "backend is down")

	_, err := env.svc.ValidateOIDCAuthCallback(context.Background(), url.Values{
		"code":  []string{"auth-code"},
		"state": []string{req.StateToken},
	})
	require.Error(t, err)
}

// The code exchange must carry the PKCE verifier that was generated for this
// request, and the same redirect_uri that was sent on the authorization URL.
func TestValidateOIDCAuthCallbackSendsPKCEVerifier(t *testing.T) {
	t.Parallel()
	env := setupTestEnv(t)

	req := env.startLogin(t, types.OIDCAuthRequest{
		ClientRedirectURL: "http://127.0.0.1:41234/callback?secret_key=abc",
		CertTTL:           time.Hour,
	})
	env.google.setIDToken(env.google.issueToken(t, tokenOpts{nonce: NonceForStateToken(req.StateToken)}))

	_, err := env.svc.ValidateOIDCAuthCallback(context.Background(), url.Values{
		"code":  []string{"auth-code"},
		"state": []string{req.StateToken},
	})
	require.NoError(t, err)

	form := env.google.tokenRequestForm()
	require.Equal(t, "authorization_code", form.Get("grant_type"))
	require.Equal(t, "auth-code", form.Get("code"))
	require.Equal(t, req.PkceVerifier, form.Get("code_verifier"))
	require.Equal(t, testRedirectURL, form.Get("redirect_uri"))
}

// ---------------------------------------------------------------------------
// User handling
// ---------------------------------------------------------------------------

// The collision guard. Without it a Google identity whose derived username
// matches an existing local account -- say a local "admin" -- takes that
// account over.
func TestValidateOIDCAuthCallbackLocalUserCollision(t *testing.T) {
	t.Parallel()
	env := setupTestEnv(t)
	ctx := context.Background()

	const username = "alice@" + testHostedDomain

	local, err := types.NewUser(username)
	require.NoError(t, err)
	local.SetRoles([]string{testRole})
	// A user created by an administrator, not by this connector.
	local.SetCreatedBy(types.CreatedBy{
		User: types.UserRef{Name: "admin"},
		Time: time.Now().UTC(),
	})
	_, err = env.authServer.CreateUser(ctx, local)
	require.NoError(t, err)

	req := env.startLogin(t, types.OIDCAuthRequest{
		ClientRedirectURL: "http://127.0.0.1:41234/callback?secret_key=abc",
		CertTTL:           time.Hour,
	})
	env.google.setIDToken(env.google.issueToken(t, tokenOpts{
		nonce: NonceForStateToken(req.StateToken),
		email: username,
	}))

	_, err = env.svc.ValidateOIDCAuthCallback(ctx, url.Values{
		"code":  []string{"auth-code"},
		"state": []string{req.StateToken},
	})
	require.Error(t, err)
	require.True(t, trace.IsAlreadyExists(err), "expected AlreadyExists, got %v", err)
	requireLoginEvent(t, env, events.UserSSOLoginFailureCode, "already exists")

	// The local user must be untouched: still no OIDC identity attached.
	after, err := env.authServer.GetUser(ctx, username, false)
	require.NoError(t, err)
	require.Empty(t, after.GetOIDCIdentities())
	require.Nil(t, after.GetCreatedBy().Connector)
}

func TestValidateOIDCAuthCallbackCreatesAndUpdatesUser(t *testing.T) {
	t.Parallel()
	env := setupTestEnv(t)
	ctx := context.Background()

	const username = "alice@" + testHostedDomain

	login := func() {
		req := env.startLogin(t, types.OIDCAuthRequest{
			ClientRedirectURL: "http://127.0.0.1:41234/callback?secret_key=abc",
			CertTTL:           time.Hour,
		})
		env.google.setIDToken(env.google.issueToken(t, tokenOpts{
			nonce: NonceForStateToken(req.StateToken),
			email: username,
		}))
		_, err := env.svc.ValidateOIDCAuthCallback(ctx, url.Values{
			"code":  []string{"auth-code"},
			"state": []string{req.StateToken},
		})
		require.NoError(t, err)
	}

	login()

	user, err := env.authServer.GetUser(ctx, username, false)
	require.NoError(t, err)
	require.Equal(t, []string{testRole}, user.GetRoles())
	require.Equal(t, []types.ExternalIdentity{{
		ConnectorID: testConnectorID,
		Username:    username,
		UserID:      "1234567890",
	}}, user.GetOIDCIdentities())
	require.Equal(t, types.KindOIDC, user.GetCreatedBy().Connector.Type)
	require.Equal(t, testConnectorID, user.GetCreatedBy().Connector.ID)
	// The email address is a trait so roles can template on it.
	require.Equal(t, []string{username}, user.GetTraits()["email"])
	require.Equal(t, []string{testHostedDomain}, user.GetTraits()["hd"])

	// A second login for the same connector updates rather than colliding.
	login()

	user, err = env.authServer.GetUser(ctx, username, false)
	require.NoError(t, err)
	require.Equal(t, []string{testRole}, user.GetRoles())
}

// tctl sso test must never write a user.
func TestValidateOIDCAuthCallbackSSOTestFlowWritesNothing(t *testing.T) {
	t.Parallel()
	env := setupTestEnv(t)
	ctx := context.Background()

	spec := env.connector.(*types.OIDCConnectorV3).Spec
	req, err := env.svc.CreateOIDCAuthRequest(ctx, types.OIDCAuthRequest{
		ConnectorID:       testConnectorID,
		ConnectorSpec:     &spec,
		SSOTestFlow:       true,
		ClientRedirectURL: "http://127.0.0.1:41234/callback?secret_key=abc",
		CertTTL:           time.Hour,
	})
	require.NoError(t, err)

	env.google.setIDToken(env.google.issueToken(t, tokenOpts{nonce: NonceForStateToken(req.StateToken)}))

	resp, err := env.svc.ValidateOIDCAuthCallback(ctx, url.Values{
		"code":  []string{"auth-code"},
		"state": []string{req.StateToken},
	})
	require.NoError(t, err)
	require.Equal(t, "alice@"+testHostedDomain, resp.Username)
	// No session, no certificates.
	require.Nil(t, resp.Session)
	require.Empty(t, resp.Cert)
	require.Empty(t, resp.TLSCert)

	// And crucially: no user.
	_, err = env.authServer.GetUser(ctx, "alice@"+testHostedDomain, false)
	require.True(t, trace.IsNotFound(err), "SSOTestFlow must not create a user, got %v", err)

	requireLoginEvent(t, env, events.UserSSOTestFlowLoginCode, "")

	// The diagnostic record must have been written so tctl sso test can show it.
	require.Contains(t, env.identity.diagInfos, req.StateToken)
	require.True(t, env.identity.diagInfos[req.StateToken].Success)
}

func TestValidateOIDCAuthCallbackSSOTestFlowRecordsFailureDiagnostics(t *testing.T) {
	t.Parallel()
	env := setupTestEnv(t)
	ctx := context.Background()

	spec := env.connector.(*types.OIDCConnectorV3).Spec
	req, err := env.svc.CreateOIDCAuthRequest(ctx, types.OIDCAuthRequest{
		ConnectorID:       testConnectorID,
		ConnectorSpec:     &spec,
		SSOTestFlow:       true,
		ClientRedirectURL: "http://127.0.0.1:41234/callback?secret_key=abc",
		CertTTL:           time.Hour,
	})
	require.NoError(t, err)

	env.google.setIDToken(env.google.issueToken(t, tokenOpts{
		nonce:            NonceForStateToken(req.StateToken),
		omitHostedDomain: true,
	}))

	_, err = env.svc.ValidateOIDCAuthCallback(ctx, url.Values{
		"code":  []string{"auth-code"},
		"state": []string{req.StateToken},
	})
	require.Error(t, err)
	requireLoginEvent(t, env, events.UserSSOTestFlowLoginFailureCode, "no hosted domain")

	info, ok := env.identity.diagInfos[req.StateToken]
	require.True(t, ok)
	require.False(t, info.Success)
	require.NotEmpty(t, info.Error)
}

// ---------------------------------------------------------------------------
// Web and console flows
// ---------------------------------------------------------------------------

func TestValidateOIDCAuthCallbackWebSession(t *testing.T) {
	t.Parallel()
	env := setupTestEnvWithCAs(t)
	ctx := context.Background()

	req := env.startLogin(t, types.OIDCAuthRequest{
		CreateWebSession: true,
		ClientLoginIP:    "10.0.0.1",
		ClientUserAgent:  "test-agent",
	})
	env.google.setIDToken(env.google.issueToken(t, tokenOpts{nonce: NonceForStateToken(req.StateToken)}))

	resp, err := env.svc.ValidateOIDCAuthCallback(ctx, url.Values{
		"code":  []string{"auth-code"},
		"state": []string{req.StateToken},
	})
	require.NoError(t, err)
	require.NotNil(t, resp.Session)
	require.Equal(t, "alice@"+testHostedDomain, resp.Session.GetUser())
	require.Empty(t, resp.Cert, "web flow should not issue certificates")
}

func TestValidateOIDCAuthCallbackConsoleCerts(t *testing.T) {
	t.Parallel()
	env := setupTestEnvWithCAs(t)
	ctx := context.Background()

	sshPub, tlsPub := testPublicKeys(t)

	req := env.startLogin(t, types.OIDCAuthRequest{
		ClientRedirectURL: "http://127.0.0.1:41234/callback?secret_key=abc",
		SshPublicKey:      sshPub,
		TlsPublicKey:      tlsPub,
		CertTTL:           time.Hour,
		RouteToCluster:    "me.localhost",
	})
	env.google.setIDToken(env.google.issueToken(t, tokenOpts{nonce: NonceForStateToken(req.StateToken)}))

	resp, err := env.svc.ValidateOIDCAuthCallback(ctx, url.Values{
		"code":  []string{"auth-code"},
		"state": []string{req.StateToken},
	})
	require.NoError(t, err)
	require.NotEmpty(t, resp.Cert)
	require.NotEmpty(t, resp.TLSCert)
	// The console client needs the host CA to trust the cluster it is about to
	// connect to.
	require.Len(t, resp.HostSigners, 1)
	require.Equal(t, types.HostCA, resp.HostSigners[0].GetType())
	require.Nil(t, resp.Session, "console flow should not create a web session")
}

// Google's "sub" is immutable and never reused; an email address is not. A
// recycled address must not inherit the previous holder's Teleport user.
func TestValidateOIDCAuthCallbackRejectsRecycledEmailAddress(t *testing.T) {
	t.Parallel()
	env := setupTestEnv(t)
	ctx := context.Background()

	login := func(subject string) error {
		req := env.startLogin(t, types.OIDCAuthRequest{
			ClientRedirectURL: "http://127.0.0.1:41234/callback?secret_key=abc",
			CertTTL:           time.Hour,
		})
		env.google.setIDToken(env.google.issueToken(t, tokenOpts{
			nonce:   NonceForStateToken(req.StateToken),
			subject: subject,
		}))
		_, err := env.svc.ValidateOIDCAuthCallback(ctx, url.Values{
			"code":  []string{"auth-code"},
			"state": []string{req.StateToken},
		})
		return err
	}

	require.NoError(t, login(testGoogleSubject))
	// Same address, different Google account.
	err := login("9999999999")
	require.Error(t, err)
	require.True(t, trace.IsAlreadyExists(err), "expected AlreadyExists, got %v", err)
	requireLoginEvent(t, env, events.UserSSOLoginFailureCode, "different Google account")

	// The original user is untouched.
	user, err := env.authServer.GetUser(ctx, "alice@"+testHostedDomain, false)
	require.NoError(t, err)
	require.Equal(t, testGoogleSubject, user.GetOIDCIdentities()[0].UserID)
}

// ErrUnauthorizedIdentity must satisfy two contracts at once: errors.Is for the
// proxy's "unauthorized" redirect, and trace.IsAccessDenied so the error still
// maps to 403 everywhere trace errors are converted.
func TestUnauthorizedIdentityErrorContract(t *testing.T) {
	t.Parallel()

	err := unauthorizedf("account %q is not in %q", "bob@gmail.com", "example.com")
	require.True(t, errors.Is(err, ErrUnauthorizedIdentity))
	require.True(t, trace.IsAccessDenied(err))
	require.Contains(t, err.Error(), "bob@gmail.com")

	// An unrelated access-denied error must NOT match the sentinel, or the
	// proxy would show "your account is not allowed" for, say, a forged token.
	require.False(t, errors.Is(trace.AccessDenied("nope"), ErrUnauthorizedIdentity))
}

func TestClaimsUsername(t *testing.T) {
	t.Parallel()

	claims := &googleClaims{Email: "alice@example.com"}
	claims.Subject = "sub-123"

	for _, tc := range []struct {
		claimName string
		want      string
		wantErr   bool
	}{
		{claimName: "", want: "alice@example.com"},
		{claimName: "email", want: "alice@example.com"},
		{claimName: "sub", want: "sub-123"},
		// A user-editable claim must not be usable as a username, or a user
		// could choose their own Teleport identity.
		{claimName: "name", wantErr: true},
		{claimName: "hd", wantErr: true},
	} {
		t.Run("claim="+tc.claimName, func(t *testing.T) {
			got, err := claims.username(tc.claimName)
			if tc.wantErr {
				require.Error(t, err)
				return
			}
			require.NoError(t, err)
			require.Equal(t, tc.want, got)
		})
	}
}
