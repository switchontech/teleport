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
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/gravitational/trace"
	"github.com/jonboulle/clockwork"
	"github.com/stretchr/testify/require"
	"golang.org/x/crypto/ssh"

	"github.com/gravitational/teleport/api/types"
	"github.com/gravitational/teleport/lib/auth"
	"github.com/gravitational/teleport/lib/auth/authtest"
	authority "github.com/gravitational/teleport/lib/auth/testauthority"
	"github.com/gravitational/teleport/lib/backend/memory"
	"github.com/gravitational/teleport/lib/cryptosuites"
	"github.com/gravitational/teleport/lib/events/eventstest"
	"github.com/gravitational/teleport/lib/modules"
	"github.com/gravitational/teleport/lib/oidc/fakeissuer"
	"github.com/gravitational/teleport/lib/services"
	"github.com/gravitational/teleport/lib/utils/log/logtest"
)

const (
	testHostedDomain = "example.com"
	testClientID     = "test-client-id.apps.googleusercontent.com"
	testClientSecret = "test-client-secret"
	testRedirectURL  = "https://proxy.example.com:3080/v1/webapi/oidc/callback"
	testConnectorID  = "google"
	// testGoogleSubject is the "sub" claim: Google's immutable account id.
	testGoogleSubject = "1234567890"
	testRole          = "access"
)

// fakeIdentity is an in-memory stand-in for the parts of services.Identity this
// service uses.
//
// It is a fake rather than the real local.IdentityService because
// DeleteOIDCAuthRequest is added by Slice 1 and does not exist in this tree
// yet. The behaviour it models -- get returns what was stored, delete makes the
// next get fail with NotFound -- is exactly what Slice 1's merge criteria
// require, so these tests will keep passing once the real implementation lands.
type fakeIdentity struct {
	mu        sync.Mutex
	requests  map[string]*types.OIDCAuthRequest
	diagInfos map[string]types.SSODiagnosticInfo

	// deleteErr, when set, makes DeleteOIDCAuthRequest fail. Used to check that
	// we fail closed when the state token cannot be consumed.
	deleteErr error
}

func newFakeIdentity() *fakeIdentity {
	return &fakeIdentity{
		requests:  make(map[string]*types.OIDCAuthRequest),
		diagInfos: make(map[string]types.SSODiagnosticInfo),
	}
}

func (f *fakeIdentity) CreateOIDCAuthRequest(ctx context.Context, req types.OIDCAuthRequest, ttl time.Duration) error {
	if err := req.Check(); err != nil {
		return trace.Wrap(err)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, ok := f.requests[req.StateToken]; ok {
		return trace.AlreadyExists("auth request %q already exists", req.StateToken)
	}
	cloned := req
	f.requests[req.StateToken] = &cloned
	return nil
}

func (f *fakeIdentity) GetOIDCAuthRequest(ctx context.Context, stateToken string) (*types.OIDCAuthRequest, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	req, ok := f.requests[stateToken]
	if !ok {
		return nil, trace.NotFound("auth request %q not found", stateToken)
	}
	cloned := *req
	return &cloned, nil
}

func (f *fakeIdentity) DeleteOIDCAuthRequest(ctx context.Context, stateToken string) error {
	if f.deleteErr != nil {
		return f.deleteErr
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, ok := f.requests[stateToken]; !ok {
		return trace.NotFound("auth request %q not found", stateToken)
	}
	delete(f.requests, stateToken)
	return nil
}

func (f *fakeIdentity) CreateSSODiagnosticInfo(ctx context.Context, authKind, authRequestID string, entry types.SSODiagnosticInfo) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.diagInfos[authRequestID] = entry
	return nil
}

func (f *fakeIdentity) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.requests)
}

// fakeGoogle is a stand-in for Google's authorization server. Discovery and
// JWKS are served by lib/oidc/fakeissuer (the same fake the rest of the tree
// verifies tokens against); only the token endpoint, which fakeissuer does not
// implement, is hosted here.
type fakeGoogle struct {
	idp      *fakeissuer.IDP
	otherIDP *fakeissuer.IDP // different key, used to forge bad signatures
	tokenSrv *httptest.Server

	mu       sync.Mutex
	idToken  string
	lastForm url.Values
}

func newFakeGoogle(t *testing.T) *fakeGoogle {
	t.Helper()
	logger := logtest.NewLogger()

	idp, err := fakeissuer.NewIDP(logger)
	require.NoError(t, err)
	t.Cleanup(idp.Close)

	otherIDP, err := fakeissuer.NewIDP(logger)
	require.NoError(t, err)
	t.Cleanup(otherIDP.Close)

	g := &fakeGoogle{idp: idp, otherIDP: otherIDP}

	mux := http.NewServeMux()
	mux.HandleFunc("/token", g.handleToken)
	g.tokenSrv = httptest.NewServer(mux)
	t.Cleanup(g.tokenSrv.Close)

	idp.SetEndpoints(idp.IssuerURL()+"/authorize", g.tokenSrv.URL+"/token")
	return g
}

func (g *fakeGoogle) issuer() string { return g.idp.IssuerURL() }

func (g *fakeGoogle) handleToken(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	g.mu.Lock()
	g.lastForm = r.PostForm
	idToken := g.idToken
	g.mu.Unlock()

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"access_token": "fake-access-token",
		"token_type":   "Bearer",
		"expires_in":   3600,
		"id_token":     idToken,
	})
}

// setIDToken sets the ID token the fake token endpoint will return.
func (g *fakeGoogle) setIDToken(token string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.idToken = token
}

func (g *fakeGoogle) tokenRequestForm() url.Values {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.lastForm
}

// tokenOpts describes the ID token the fake Google should mint. The zero value
// is filled in with a valid, in-domain, verified identity.
type tokenOpts struct {
	issuer   string
	audience any
	subject  string
	// omitSubject drops the "sub" claim entirely.
	omitSubject   bool
	email         string
	emailVerified any
	// hostedDomain is the "hd" claim. omitHostedDomain distinguishes "absent"
	// (a personal Gmail account) from "present but empty".
	hostedDomain     string
	omitHostedDomain bool
	nonce            string
	expires          time.Time
	// forgeSignature signs with a key the IDP does not publish.
	forgeSignature bool
}

func (g *fakeGoogle) issueToken(t *testing.T, opts tokenOpts) string {
	t.Helper()
	now := time.Now()

	claims := map[string]any{
		"iss":   cmpOr(opts.issuer, g.issuer()),
		"aud":   valueOr[any](opts.audience, testClientID),
		"iat":   now.Add(-time.Minute).Unix(),
		"nbf":   now.Add(-time.Minute).Unix(),
		"exp":   valueOrTime(opts.expires, now.Add(10*time.Minute)).Unix(),
		"email": cmpOr(opts.email, "alice@"+testHostedDomain),
		"name":  "Alice Example",
		"nonce": opts.nonce,
	}
	if !opts.omitSubject {
		claims["sub"] = cmpOr(opts.subject, testGoogleSubject)
	}
	claims["email_verified"] = valueOr[any](opts.emailVerified, true)
	if !opts.omitHostedDomain {
		claims["hd"] = cmpOr(opts.hostedDomain, testHostedDomain)
	}

	idp := g.idp
	if opts.forgeSignature {
		idp = g.otherIDP
	}
	token, err := idp.SignClaims(claims)
	require.NoError(t, err)
	return token
}

func cmpOr(v, fallback string) string {
	if v == "" {
		return fallback
	}
	return v
}

func valueOr[T any](v any, fallback T) any {
	if v == nil {
		return fallback
	}
	return v
}

func valueOrTime(v, fallback time.Time) time.Time {
	if v.IsZero() {
		return fallback
	}
	return v
}

// testEnv bundles a real auth server, a fake identity store and a fake Google.
type testEnv struct {
	authServer *auth.Server
	emitter    *eventstest.MockRecorderEmitter
	identity   *fakeIdentity
	google     *fakeGoogle
	svc        *Service
	connector  types.OIDCConnector
}

// setupTestEnv builds a lightweight auth server: enough for connector, user and
// audit behaviour, but with no certificate authorities, so it cannot issue web
// sessions or certificates. Use setupTestEnvWithCAs for those.
func setupTestEnv(t *testing.T) *testEnv {
	t.Helper()
	ctx := context.Background()

	clock := clockwork.NewRealClock()

	bk, err := memory.New(memory.Config{Context: ctx, Clock: clock})
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, bk.Close()) })

	clusterName, err := services.NewClusterNameWithRandomID(types.ClusterNameSpecV2{
		ClusterName: "me.localhost",
	})
	require.NoError(t, err)

	keygen, err := authority.NewKeygen(modules.BuildOSS, clock.Now)
	require.NoError(t, err)

	authServer, err := auth.NewServer(&auth.InitConfig{
		ClusterName:            clusterName,
		Backend:                bk,
		VersionStorage:         authtest.NewFakeTeleportVersion(),
		Authority:              keygen,
		SkipPeriodicOperations: true,
		HostUUID:               uuid.NewString(),
	})
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, authServer.Close()) })

	emitter := &eventstest.MockRecorderEmitter{}
	authServer.SetEmitter(emitter)

	role, err := types.NewRole(testRole, types.RoleSpecV6{})
	require.NoError(t, err)
	_, err = authServer.UpsertRole(ctx, role)
	require.NoError(t, err)

	return finishTestEnv(t, authServer, emitter)
}

// setupTestEnvWithCAs builds a fully initialised auth server (cluster name,
// certificate authorities, auth preference) so that web sessions and user
// certificates can actually be issued. It is slower, so only the tests that
// need it use it.
func setupTestEnvWithCAs(t *testing.T) *testEnv {
	t.Helper()
	ctx := context.Background()

	testAuth, err := authtest.NewAuthServer(authtest.AuthServerConfig{
		Dir:         t.TempDir(),
		ClusterName: "me.localhost",
		Clock:       clockwork.NewRealClock(),
	})
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, testAuth.Close()) })

	role, err := types.NewRole(testRole, types.RoleSpecV6{})
	require.NoError(t, err)
	_, err = testAuth.AuthServer.UpsertRole(ctx, role)
	require.NoError(t, err)

	emitter := &eventstest.MockRecorderEmitter{}
	testAuth.AuthServer.SetEmitter(emitter)

	return finishTestEnv(t, testAuth.AuthServer, emitter)
}

func finishTestEnv(t *testing.T, authServer *auth.Server, emitter *eventstest.MockRecorderEmitter) *testEnv {
	t.Helper()
	ctx := context.Background()

	google := newFakeGoogle(t)
	connector := testConnector(t, google.issuer())
	_, err := authServer.Services.CreateOIDCConnector(ctx, connector)
	require.NoError(t, err)

	identity := newFakeIdentity()
	svc := newTestService(t, google, authServer, identity)

	emitter.Reset()

	return &testEnv{
		authServer: authServer,
		emitter:    emitter,
		identity:   identity,
		google:     google,
		svc:        svc,
		connector:  connector,
	}
}

func newTestService(t *testing.T, google *fakeGoogle, authServer AuthService, identity Identity) *Service {
	t.Helper()
	svc, err := New(Config{
		HostedDomain: testHostedDomain,
		Identity:     identity,
		Auth:         authServer,
		Logger:       logtest.NewLogger(),
	})
	require.NoError(t, err)

	// The fake issuer is not Google, and it signs with ES256 rather than
	// RS256. Both restrictions are unexported precisely so that nothing but a
	// test in this package can relax them.
	svc.allowedIssuer = google.issuer()
	svc.signingAlgs = []string{"ES256"}
	return svc
}

func testConnector(t *testing.T, issuerURL string) types.OIDCConnector {
	t.Helper()
	connector, err := types.NewOIDCConnector(testConnectorID, types.OIDCConnectorSpecV3{
		IssuerURL:    issuerURL,
		ClientID:     testClientID,
		ClientSecret: testClientSecret,
		RedirectURLs: []string{testRedirectURL},
		ClaimsToRoles: []types.ClaimMapping{{
			Claim: "hd",
			Value: testHostedDomain,
			Roles: []string{testRole},
		}},
	})
	require.NoError(t, err)
	return connector
}

// startLogin performs the request side and returns the stored auth request.
func (e *testEnv) startLogin(t *testing.T, req types.OIDCAuthRequest) *types.OIDCAuthRequest {
	t.Helper()
	if req.ConnectorID == "" {
		req.ConnectorID = testConnectorID
	}
	out, err := e.svc.CreateOIDCAuthRequest(context.Background(), req)
	require.NoError(t, err)
	return out
}

// nopAuthService satisfies [AuthService] for constructor tests that never reach
// any of its methods. Embedding the nil interface means an unexpected call
// panics loudly rather than silently returning a zero value.
type nopAuthService struct{ AuthService }

// testPublicKeys returns an SSH authorized_keys blob and a PEM public key that
// the auth server will accept for certificate issuance.
func testPublicKeys(t *testing.T) (sshPub, tlsPub []byte) {
	t.Helper()

	key, err := cryptosuites.GenerateKeyWithAlgorithm(cryptosuites.ECDSAP256)
	require.NoError(t, err)

	sshSigner, err := ssh.NewPublicKey(key.Public())
	require.NoError(t, err)
	sshPub = ssh.MarshalAuthorizedKey(sshSigner)

	der, err := x509.MarshalPKIXPublicKey(key.Public())
	require.NoError(t, err)
	tlsPub = pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der})

	return sshPub, tlsPub
}
