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

// Package oidcgoogle implements [auth.OIDCService] for exactly one identity
// provider: Google, restricted to a single Google Workspace hosted domain.
//
// It is deliberately narrower than a general purpose OIDC connector. The
// narrowness is the security property: every authenticated user must present a
// Google-signed ID token whose "hd" (hosted domain) claim is exactly the domain
// this process was configured with. Anything else -- another issuer, a personal
// Gmail account (which carries no "hd" claim at all), an unverified address --
// is rejected before any Teleport user is looked up or created.
//
// Threat model notes for reviewers:
//
//   - The ID token is verified (signature, iss, aud, exp, nonce) BEFORE any
//     claim in it is read for an authorization decision. See
//     [Service.ValidateOIDCAuthCallback].
//   - The hosted domain is never derived from the "email" claim. Suffix
//     matching an email is the classic break: "attacker@example.com.evil.net"
//     passes a naive strings.HasSuffix check. Only "hd" is trusted, and only
//     after verification.
//   - The state token is single use: it is deleted from the backend as soon as
//     it is read, before the authorization code is exchanged.
//   - The client redirect URL is validated with [sso.ValidateClientRedirect] on
//     the request side. Skipping that check is a certificate theft
//     vulnerability: an attacker sends a victim a login link carrying the
//     attacker's redirect_url, the victim completes a genuine Google login, and
//     the attacker's listener receives the victim's certificates.
package oidcgoogle

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/gravitational/trace"
	"github.com/jonboulle/clockwork"
	"github.com/zitadel/oidc/v3/pkg/client"
	"github.com/zitadel/oidc/v3/pkg/client/rp"
	zoidc "github.com/zitadel/oidc/v3/pkg/oidc"
	"golang.org/x/oauth2"

	"github.com/gravitational/teleport"
	"github.com/gravitational/teleport/api/constants"
	apidefaults "github.com/gravitational/teleport/api/defaults"
	"github.com/gravitational/teleport/api/types"
	apievents "github.com/gravitational/teleport/api/types/events"
	"github.com/gravitational/teleport/api/utils/keys/hardwarekey"
	"github.com/gravitational/teleport/lib/auth"
	"github.com/gravitational/teleport/lib/auth/authclient"
	"github.com/gravitational/teleport/lib/authz"
	"github.com/gravitational/teleport/lib/client/sso"
	"github.com/gravitational/teleport/lib/defaults"
	"github.com/gravitational/teleport/lib/events"
	"github.com/gravitational/teleport/lib/loginrule"
	teleoidc "github.com/gravitational/teleport/lib/oidc"
	"github.com/gravitational/teleport/lib/services"
	"github.com/gravitational/teleport/lib/utils"
)

// GoogleIssuerURL is the only issuer URL an OIDC connector may declare for this
// service. Google publishes its discovery document at
// https://accounts.google.com/.well-known/openid-configuration and its ID
// tokens carry this exact "iss" value.
//
// Note that Google historically also issued tokens with an "accounts.google.com"
// (no scheme) issuer. We do not accept that form: the connector's issuer_url,
// the discovery document's issuer and the token's "iss" must all agree on the
// https form, which is what Google emits today.
const GoogleIssuerURL = "https://accounts.google.com"

// ErrUnauthorizedIdentity marks a rejection where the user successfully
// authenticated to Google -- the ID token verified -- but is not permitted to
// log in to this cluster: wrong (or absent) hosted domain, unverified email, or
// no roles mapped.
//
// It is the OIDC analogue of [auth.ErrGithubNoTeams], but note how far it
// actually travels. ValidateOIDCAuthCallback runs on Auth and the proxy calls it
// over gRPC, where a trace error is flattened to a status code plus a message
// string and rebuilt client-side as a fresh error. A sentinel made with
// errors.New exists only in the Auth process, so errors.Is against it CANNOT
// succeed on the proxy. [auth.ErrGithubNoTeams] survives that boundary only
// because it is a trace.BadParameter, whose Is compares message strings.
//
// The consequence today is that an unauthorized identity reaches the generic
// failure page rather than LoginFailedUnauthorizedRedirectURL. That is a UX
// shortfall, not a security one: the rejection still happens on Auth and the
// UserLogin failure event still records the real reason. Distinguishing the two
// cases in the browser needs a different mechanism and is left as a follow-up.
//
// Within the Auth process the sentinel behaves as documented, which is what the
// multi-error Unwrap below is for.
//
// Do NOT use it for token verification failures. A bad signature, a wrong
// audience or a replayed state is not an unauthorized user, it is an attack or
// a broken client, and it should not be reported to the browser as "your
// account is not allowed".
var ErrUnauthorizedIdentity = errors.New("this Google identity is not authorized to log in to this cluster")

// unauthorizedIdentityError is an access-denied error that also matches
// [ErrUnauthorizedIdentity] under errors.Is.
//
// The multi-error Unwrap is what makes both work at once:
//   - trace.IsAccessDenied(err) finds the embedded *trace.AccessDeniedError, so
//     the error still maps to 403 everywhere trace errors are converted;
//   - errors.Is(err, ErrUnauthorizedIdentity) finds the sentinel.
//
// A plain trace.AccessDenied sentinel cannot be used here because
// trace.AccessDeniedError.Is compares message strings, and every rejection
// carries a different (deliberately specific) message.
type unauthorizedIdentityError struct {
	denied *trace.AccessDeniedError
}

func (e *unauthorizedIdentityError) Error() string { return e.denied.Error() }

func (e *unauthorizedIdentityError) Unwrap() []error {
	return []error{e.denied, ErrUnauthorizedIdentity}
}

// unauthorizedf builds an [unauthorizedIdentityError]. The message is the
// reason recorded in the UserLogin audit event, so it should say precisely why
// the identity was refused.
func unauthorizedf(format string, args ...any) error {
	return trace.Wrap(&unauthorizedIdentityError{
		denied: &trace.AccessDeniedError{Message: fmt.Sprintf(format, args...)},
	})
}

// googleScopes are the OAuth2 scopes requested. They are fixed rather than read
// from the connector so that a connector edit cannot broaden what this
// deployment asks Google for. "openid" and "email" give us sub/email/
// email_verified/hd; "profile" gives us the display name used for traits.
var googleScopes = []string{"openid", "email", "profile"}

// discoveryTTL is how long an OIDC discovery document is cached. Google rotates
// endpoints very rarely; caching keeps login off the critical path of an
// external HTTP call on every request.
const discoveryTTL = time.Hour

// Identity is the subset of [services.Identity] used by this service.
//
// DeleteOIDCAuthRequest is added by Slice 1; it does not exist upstream. It is
// what makes state tokens single use rather than merely short lived.
type Identity interface {
	CreateOIDCAuthRequest(ctx context.Context, req types.OIDCAuthRequest, ttl time.Duration) error
	GetOIDCAuthRequest(ctx context.Context, stateToken string) (*types.OIDCAuthRequest, error)
	DeleteOIDCAuthRequest(ctx context.Context, stateToken string) error
	CreateSSODiagnosticInfo(ctx context.Context, authKind string, authRequestID string, entry types.SSODiagnosticInfo) error
}

// AuthService is the subset of [*auth.Server] used by this service.
//
// It deliberately does NOT include auth.Server.CreateOIDCAuthRequest: that
// method delegates back into this service, so calling it here would recurse.
// Auth request persistence goes through [Identity] instead.
type AuthService interface {
	GetOIDCConnector(ctx context.Context, name string, withSecrets bool) (types.OIDCConnector, error)

	GetUser(ctx context.Context, name string, withSecrets bool) (types.User, error)
	CreateUser(ctx context.Context, user types.User) (types.User, error)
	UpdateUser(ctx context.Context, user types.User) (types.User, error)
	GetUserOrLoginState(ctx context.Context, username string) (services.UserState, error)
	CallLoginHooks(ctx context.Context, user types.User) error
	GetLoginRuleEvaluator() loginrule.Evaluator
	GetRole(ctx context.Context, name string) (types.Role, error)

	CreateWebSessionFromReq(ctx context.Context, req auth.NewWebSessionRequest) (types.WebSession, error)
	CreateSessionCerts(ctx context.Context, req *auth.SessionCertsRequest) ([]byte, []byte, error)
	GetClusterName(ctx context.Context) (types.ClusterName, error)
	GetCertAuthority(ctx context.Context, id types.CertAuthID, loadKeys bool) (types.CertAuthority, error)
	ClientOptionsForLogin(userState services.UserState) (authclient.ClientOptions, error)

	EmitAuditEvent(ctx context.Context, e apievents.AuditEvent) error
}

// Config configures a [Service].
type Config struct {
	// HostedDomain is the Google Workspace hosted domain that every
	// authenticating user must belong to, e.g. "example.com". It is compared
	// against the "hd" claim of the verified ID token.
	//
	// This is a process level setting rather than a connector field on purpose:
	// a second connector created later must not be able to silently admit any
	// Google account.
	//
	// It is required. See [New], which fails closed when it is empty.
	HostedDomain string
	// Identity persists and retrieves OIDC auth requests and SSO diagnostics.
	Identity Identity
	// Auth provides the auth server operations needed to resolve connectors,
	// users, roles, sessions and certificates.
	Auth AuthService
	// Clock is used for user expiry and cache TTLs. Defaults to a real clock.
	//
	// Note: it does NOT control ID token expiry validation, which is performed
	// by github.com/zitadel/oidc against the wall clock.
	Clock clockwork.Clock
	// Logger defaults to a package logger.
	Logger *slog.Logger
	// HTTPClient is used for OIDC discovery and the token exchange. Defaults to
	// [http.DefaultClient].
	HTTPClient *http.Client
}

// Service implements [auth.OIDCService] against Google, restricted to a single
// Google Workspace hosted domain.
type Service struct {
	cfg Config

	// hostedDomain is cfg.HostedDomain, normalised to lower case ASCII.
	hostedDomain string

	// allowedIssuer is the issuer URL a connector is required to declare.
	//
	// It is [GoogleIssuerURL] in production. There is deliberately no exported
	// field or config option to change it: a mistyped or maliciously edited
	// connector must not be able to point Teleport at an attacker controlled
	// IdP. Tests in this package override it directly.
	allowedIssuer string

	// signingAlgs is the set of JWS algorithms accepted for the ID token
	// signature. It is pinned to RS256 (what Google actually uses) rather than
	// left at the library default of RS256/ES256/PS256: a narrower set is one
	// fewer moving part in signature verification. As with allowedIssuer there
	// is no exported knob; tests in this package override it.
	signingAlgs []string

	validator      *teleoidc.CachingTokenValidator[*googleClaims]
	discoveryCache *utils.FnCache
}

// New returns a new Google OIDC service.
//
// It fails closed: without a hosted domain there is no way to tell a corporate
// account from a personal Gmail account, so construction is refused rather than
// defaulting to "allow any Google account".
func New(cfg Config) (*Service, error) {
	if cfg.Identity == nil {
		return nil, trace.BadParameter("identity service is required")
	}
	if cfg.Auth == nil {
		return nil, trace.BadParameter("auth service is required")
	}
	if cfg.Clock == nil {
		cfg.Clock = clockwork.NewRealClock()
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.With(teleport.ComponentKey, "oidc:google")
	}
	if cfg.HTTPClient == nil {
		cfg.HTTPClient = http.DefaultClient
	}

	hostedDomain, err := normalizeHostedDomain(cfg.HostedDomain)
	if err != nil {
		return nil, trace.Wrap(err)
	}

	validator, err := teleoidc.NewCachingTokenValidator[*googleClaims](cfg.Clock)
	if err != nil {
		return nil, trace.Wrap(err)
	}

	discoveryCache, err := utils.NewFnCache(utils.FnCacheConfig{
		Clock:       cfg.Clock,
		TTL:         discoveryTTL,
		ReloadOnErr: true,
	})
	if err != nil {
		return nil, trace.Wrap(err)
	}

	return &Service{
		cfg:            cfg,
		hostedDomain:   hostedDomain,
		allowedIssuer:  GoogleIssuerURL,
		signingAlgs:    []string{"RS256"},
		validator:      validator,
		discoveryCache: discoveryCache,
	}, nil
}

// NonceForStateToken derives the OIDC "nonce" bound to an auth request from its
// state token.
//
// The binding rule, which Slice 1 records and every slice must agree on, is:
//
//	nonce = hex(SHA-256(StateToken))
//
// Deriving rather than storing avoids adding a field to the (generated,
// Apache-licensed) api/ protobufs. The security properties we need are that the
// nonce is unpredictable to anyone who has not seen the state token, and that it
// is reproducible at callback time from the stored request. A SHA-256 of a
// 256-bit cryptographically random state token gives both.
//
// Note the nonce is NOT a secret that must be hidden from the client: it travels
// through the user agent to Google in the authorization URL, exactly like the
// state token does. Its job is to bind the ID token to this specific request so
// a token minted for another request cannot be replayed here.
func NonceForStateToken(stateToken string) string {
	sum := sha256.Sum256([]byte(stateToken))
	return hex.EncodeToString(sum[:])
}

// normalizeHostedDomain validates and lower-cases the configured hosted domain.
//
// Non-ASCII input is rejected. Unicode case folding is not a safe basis for a
// security comparison (distinct code points can fold together), and Google
// hosted domains are ASCII (IDNs appear in their punycode form).
func normalizeHostedDomain(domain string) (string, error) {
	if domain == "" {
		return "", trace.BadParameter("google hosted domain is required: refusing to start an OIDC service that would accept any Google account")
	}
	if !isASCII(domain) {
		return "", trace.BadParameter("google hosted domain %q must be ASCII (use the punycode form of an internationalised domain)", domain)
	}
	lowered := strings.ToLower(domain)
	if !strings.Contains(lowered, ".") || strings.ContainsAny(lowered, " \t/:@") {
		return "", trace.BadParameter("google hosted domain %q is not a valid domain name", domain)
	}
	return lowered, nil
}

func isASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] > 0x7f {
			return false
		}
	}
	return true
}

// CreateOIDCAuthRequestForMFA is not implemented.
//
// Its only caller, lib/auth.(*Server).beginSSOMFAChallenge, is reachable only
// when the OIDC connector sets mfa.enabled: true, which this deployment does
// not do (and which checkConnector refuses outright).
//
// Operator note: Google authentication does NOT satisfy a Teleport second
// factor requirement. If second_factor is enforced, Google-authenticated users
// still need a local second factor (WebAuthn/OTP) registered in Teleport.
func (s *Service) CreateOIDCAuthRequestForMFA(ctx context.Context, req types.OIDCAuthRequest) (*types.OIDCAuthRequest, error) {
	return nil, trace.NotImplemented("SSO MFA is not supported by the Google OIDC service")
}

// CreateOIDCAuthRequest creates a new OIDC auth request and returns it with
// RedirectURL populated with the Google authorization URL the browser should be
// sent to.
func (s *Service) CreateOIDCAuthRequest(ctx context.Context, req types.OIDCAuthRequest) (*types.OIDCAuthRequest, error) {
	connector, err := s.getConnector(ctx, req)
	if err != nil {
		return nil, trace.Wrap(err)
	}
	if err := s.checkConnector(connector); err != nil {
		return nil, trace.Wrap(err)
	}

	// Validate the client redirect URL.
	//
	// This is the check whose absence lets an attacker steal certificates: the
	// callback hands the SSO result to ClientRedirectURL, so an unvalidated
	// value is an open redirect for credentials.
	//
	// It is skipped for CreateWebSession requests, matching
	// lib/auth.(*Server).CreateGithubAuthRequest. Those requests originate from
	// the proxy, not from a client: the proxy sets the session cookie itself and
	// redirects within its own web UI, so ClientRedirectURL there is a web UI
	// path (not a "/callback" URL) and no certificate ever leaves the proxy for
	// that URL. The proxy validates the web redirect separately.
	if !req.CreateWebSession {
		ceremonyType := sso.CeremonyTypeLogin
		if req.SSOTestFlow {
			ceremonyType = sso.CeremonyTypeTest
		}
		if err := sso.ValidateClientRedirect(req.ClientRedirectURL, ceremonyType, connector.GetClientRedirectSettings()); err != nil {
			return nil, trace.Wrap(err, auth.InvalidClientRedirectErrorMessage)
		}
	}

	// A cryptographically random state token. Everything else (the nonce, the
	// single-use property, the lookup at callback time) hangs off this value.
	req.StateToken, err = utils.CryptoRandomHex(defaults.TokenLenBytes)
	if err != nil {
		return nil, trace.Wrap(err)
	}

	// PKCE is always on. Google supports S256 and it costs nothing; we do not
	// consult connector.IsPKCEEnabled() because there is no reason this
	// deployment would ever want it off.
	req.PkceVerifier = oauth2.GenerateVerifier()

	// The redirect_uri sent to Google. The identical value must be replayed at
	// token exchange time or Google rejects the exchange.
	redirectURL, err := services.GetRedirectURL(connector, req.ProxyAddress)
	if err != nil {
		return nil, trace.Wrap(err)
	}

	oauthConfig, err := s.oauthConfig(ctx, connector, redirectURL)
	if err != nil {
		return nil, trace.Wrap(err)
	}

	opts := []oauth2.AuthCodeOption{
		oauth2.S256ChallengeOption(req.PkceVerifier),
		oauth2.SetAuthURLParam("nonce", NonceForStateToken(req.StateToken)),
		// "hd" on the authorization request is a user experience hint only: it
		// asks Google's account chooser to prefer accounts in this domain. It
		// carries NO security weight and is trivially stripped by the user
		// agent. The enforcing check is on the "hd" claim of the verified ID
		// token in ValidateOIDCAuthCallback.
		oauth2.SetAuthURLParam("hd", s.hostedDomain),
	}
	if prompt := connector.GetPrompt(); prompt != "" {
		opts = append(opts, oauth2.SetAuthURLParam("prompt", prompt))
	}

	req.RedirectURL = oauthConfig.AuthCodeURL(req.StateToken, opts...)

	if err := s.cfg.Identity.CreateOIDCAuthRequest(ctx, req, defaults.OIDCAuthRequestTTL); err != nil {
		return nil, trace.Wrap(err)
	}

	s.cfg.Logger.DebugContext(ctx, "Created Google OIDC auth request",
		"connector", connector.GetName(),
		"create_web_session", req.CreateWebSession,
		"test_flow", req.SSOTestFlow,
	)

	return &req, nil
}

// getConnector resolves the connector for a request.
//
// A caller-supplied ConnectorSpec is honoured ONLY for SSOTestFlow requests
// (that is what "tctl sso test" is). Accepting a spec on a real login would let
// anyone who can reach the auth API define their own IdP, client ID and role
// mapping, so it is rejected outright.
func (s *Service) getConnector(ctx context.Context, req types.OIDCAuthRequest) (types.OIDCConnector, error) {
	if req.SSOTestFlow {
		if req.ConnectorSpec == nil {
			return nil, trace.BadParameter("ConnectorSpec cannot be nil for SSOTestFlow")
		}
		if req.ConnectorID == "" {
			return nil, trace.BadParameter("ConnectorID cannot be empty")
		}
		connector, err := types.NewOIDCConnector(req.ConnectorID, *req.ConnectorSpec)
		return connector, trace.Wrap(err)
	}

	if req.ConnectorSpec != nil {
		return nil, trace.BadParameter("ConnectorSpec is only allowed when SSOTestFlow is true")
	}

	connector, err := s.cfg.Auth.GetOIDCConnector(ctx, req.ConnectorID, true)
	return connector, trace.Wrap(err)
}

// checkConnector rejects connector configurations this service cannot enforce.
//
// Everything here fails closed. The alternative -- silently ignoring a setting
// an administrator deliberately turned on -- is how security controls quietly
// stop working.
func (s *Service) checkConnector(connector types.OIDCConnector) error {
	if connector.GetIssuerURL() != s.allowedIssuer {
		return trace.AccessDenied("connector %q has issuer_url %q; this cluster only accepts Google (%q)",
			connector.GetName(), connector.GetIssuerURL(), s.allowedIssuer)
	}
	if connector.GetClientID() == "" {
		return trace.BadParameter("connector %q has no client_id", connector.GetName())
	}
	if connector.GetClientSecret() == "" {
		return trace.BadParameter("connector %q has no client_secret", connector.GetName())
	}
	// We unconditionally require email_verified == true, so a connector that
	// asks to allow unverified email is asking for something we will not do.
	if connector.GetAllowUnverifiedEmail() {
		return trace.BadParameter("connector %q sets allow_unverified_email, which this service does not support", connector.GetName())
	}
	// max_age implies verifying the "auth_time" claim, which we do not do.
	if _, ok := connector.GetMaxAge(); ok {
		return trace.BadParameter("connector %q sets max_age, which this service does not support", connector.GetName())
	}
	// Google Workspace directory lookups (group membership via a service
	// account) are not implemented; role mapping here is claim based only.
	if connector.GetGoogleServiceAccount() != "" || connector.GetGoogleServiceAccountURI() != "" || connector.GetGoogleAdminEmail() != "" {
		return trace.BadParameter("connector %q configures Google Workspace directory sync, which this service does not support", connector.GetName())
	}
	if connector.IsMFAEnabled() {
		return trace.BadParameter("connector %q enables SSO MFA, which this service does not support", connector.GetName())
	}
	return nil
}

// oauthConfig builds the OAuth2 config from the provider's discovery document.
//
// Endpoints come from discovery rather than being hardcoded so that we follow
// Google if it moves them, and so that this code is testable against a fake
// issuer without a build tag or an insecure flag.
func (s *Service) oauthConfig(ctx context.Context, connector types.OIDCConnector, redirectURL string) (*oauth2.Config, error) {
	discovery, err := s.discover(ctx, connector.GetIssuerURL())
	if err != nil {
		return nil, trace.Wrap(err)
	}
	if discovery.AuthorizationEndpoint == "" || discovery.TokenEndpoint == "" {
		return nil, trace.BadParameter("issuer %q does not advertise an authorization or token endpoint", connector.GetIssuerURL())
	}
	return &oauth2.Config{
		ClientID:     connector.GetClientID(),
		ClientSecret: connector.GetClientSecret(),
		RedirectURL:  redirectURL,
		Scopes:       googleScopes,
		Endpoint: oauth2.Endpoint{
			AuthURL:   discovery.AuthorizationEndpoint,
			TokenURL:  discovery.TokenEndpoint,
			AuthStyle: oauth2.AuthStyleInParams,
		},
	}, nil
}

func (s *Service) discover(ctx context.Context, issuerURL string) (*zoidc.DiscoveryConfiguration, error) {
	discovery, err := utils.FnCacheGet(ctx, s.discoveryCache, issuerURL, func(ctx context.Context) (*zoidc.DiscoveryConfiguration, error) {
		ctx, cancel := context.WithTimeout(ctx, defaults.HTTPRequestTimeout)
		defer cancel()
		// client.Discover verifies that the document's "issuer" matches the
		// URL we asked for, which is what stops a compromised well-known
		// document from redirecting us to another issuer.
		return client.Discover(ctx, issuerURL, s.cfg.HTTPClient)
	})
	return discovery, trace.Wrap(err)
}

// ValidateOIDCAuthCallback validates the redirect back from Google and, on
// success, returns the session and/or certificates for the authenticated user.
//
// It emits a UserLogin audit event for both success and failure. The RBAC layer
// above only emits for auth request creation failures, so callback auditing is
// this service's responsibility.
func (s *Service) ValidateOIDCAuthCallback(ctx context.Context, q url.Values) (*authclient.OIDCAuthResponse, error) {
	diagCtx := auth.NewSSODiagContext(types.KindOIDC, s.cfg.Identity)

	event := &apievents.UserLogin{
		Metadata: apievents.Metadata{
			Type: events.UserLoginEvent,
		},
		Method:             events.LoginMethodOIDC,
		ConnectionMetadata: authz.ConnectionMetadata(ctx),
	}

	resp, err := s.validateCallback(ctx, diagCtx, q)
	diagCtx.Info.Error = trace.UserMessage(err)
	event.AppliedLoginRules = diagCtx.Info.AppliedLoginRules

	diagCtx.WriteToBackend(ctx)

	if attributes, encErr := apievents.EncodeMap(diagCtx.Info.OIDCClaims); encErr != nil {
		s.cfg.Logger.DebugContext(ctx, "Failed to encode identity attributes", "error", encErr)
	} else {
		event.IdentityAttributes = attributes
	}

	if err != nil {
		event.Code = events.UserSSOLoginFailureCode
		if diagCtx.Info.TestFlow {
			event.Code = events.UserSSOTestFlowLoginFailureCode
		}
		event.Status.Success = false
		// Status.Error carries the internal reason (why we rejected);
		// Status.UserMessage carries what the user is told.
		event.Status.Error = trace.Unwrap(err).Error()
		event.Status.UserMessage = err.Error()

		if emitErr := s.cfg.Auth.EmitAuditEvent(ctx, event); emitErr != nil {
			s.cfg.Logger.WarnContext(ctx, "Failed to emit Google OIDC login failure event", "error", emitErr)
		}
		return nil, trace.Wrap(err)
	}

	event.Code = events.UserSSOLoginCode
	if diagCtx.Info.TestFlow {
		event.Code = events.UserSSOTestFlowLoginCode
	}
	event.Status.Success = true
	event.User = resp.Username

	if emitErr := s.cfg.Auth.EmitAuditEvent(ctx, event); emitErr != nil {
		s.cfg.Logger.WarnContext(ctx, "Failed to emit Google OIDC login event", "error", emitErr)
	}

	return resp, nil
}

func (s *Service) validateCallback(ctx context.Context, diagCtx *auth.SSODiagContext, q url.Values) (*authclient.OIDCAuthResponse, error) {
	stateToken := q.Get("state")
	if stateToken == "" {
		return nil, trace.WithUserMessage(
			trace.OAuth2("invalid_request", "missing state query param", q),
			"Invalid parameters received from Google.")
	}
	diagCtx.RequestID = stateToken

	// Consume the auth request. The Get+Delete pair makes the state token
	// single use: a replayed callback (whether by an attacker who observed the
	// redirect, or by a browser retry) finds nothing and is rejected. Deleting
	// BEFORE the code exchange means even a failed login burns the state.
	//
	// An expired request is already absent thanks to the backend TTL, so
	// NotFound covers both "unknown" and "expired".
	req, err := s.cfg.Identity.GetOIDCAuthRequest(ctx, stateToken)
	if err != nil {
		return nil, trace.Wrap(err, "Failed to get OIDC auth request.")
	}
	if err := s.cfg.Identity.DeleteOIDCAuthRequest(ctx, stateToken); err != nil {
		// Fail closed: if we cannot guarantee the state is consumed, we must
		// not proceed, or the state would remain replayable.
		return nil, trace.Wrap(err, "Failed to consume OIDC auth request.")
	}
	diagCtx.Info.TestFlow = req.SSOTestFlow

	// Only now that the request is known do we surface a provider-side error,
	// so that an unauthenticated caller cannot use this endpoint as an oracle.
	if errParam := q.Get("error"); errParam != "" {
		errDesc := q.Get("error_description")
		return nil, trace.WithUserMessage(
			trace.OAuth2("invalid_request", errParam, q),
			"Google returned an error: %v [%v]", errDesc, errParam)
	}

	code := q.Get("code")
	if code == "" {
		return nil, trace.WithUserMessage(
			trace.OAuth2("invalid_request", "code query param must be set", q),
			"Invalid parameters received from Google.")
	}

	connector, err := s.getConnector(ctx, *req)
	if err != nil {
		return nil, trace.Wrap(err, "Failed to get OIDC connector.")
	}
	if err := s.checkConnector(connector); err != nil {
		return nil, trace.Wrap(err)
	}
	diagCtx.Info.OIDCClaimsToRoles = connector.GetClaimsToRoles()
	diagCtx.Info.OIDCConnectorTraitMapping = connector.GetTraitMappings()

	claims, err := s.exchangeAndVerify(ctx, connector, req, code)
	if err != nil {
		return nil, trace.Wrap(err)
	}

	// Everything below this line reads verified claims. Nothing above it made
	// an authorization decision based on claim content.
	diagCtx.Info.OIDCClaims = claims.asOIDCClaims()
	diagCtx.Info.OIDCIdentity = &types.OIDCIdentity{
		ID:        claims.Subject,
		Name:      claims.Name,
		Email:     claims.Email,
		ExpiresAt: claims.Expiration.AsTime(),
	}

	if err := s.checkClaims(claims); err != nil {
		return nil, trace.Wrap(err)
	}

	params, err := s.calculateUser(ctx, diagCtx, connector, claims, req)
	if err != nil {
		return nil, trace.Wrap(err, "Failed to calculate user attributes.")
	}
	diagCtx.Info.CreateUserParams = &types.CreateUserParams{
		ConnectorName: params.ConnectorName,
		Username:      params.Username,
		Roles:         params.Roles,
		Traits:        params.Traits,
		SessionTTL:    types.Duration(params.SessionTTL),
	}

	identity := types.ExternalIdentity{
		ConnectorID: params.ConnectorName,
		Username:    params.Username,
		UserID:      params.UserID,
	}

	// SSOTestFlow must never write a user. createUser honours dryRun, and we
	// return before creating any session or certificate.
	user, err := s.createUser(ctx, params, req.SSOTestFlow)
	if err != nil {
		return nil, trace.Wrap(err, "Failed to create user from provided parameters.")
	}

	if req.SSOTestFlow {
		diagCtx.Info.Success = true
		return &authclient.OIDCAuthResponse{
			Req:      oidcAuthRequestFromProto(req),
			Identity: identity,
			Username: params.Username,
		}, nil
	}

	if err := s.cfg.Auth.CallLoginHooks(ctx, user); err != nil {
		return nil, trace.Wrap(err)
	}

	userState, err := s.cfg.Auth.GetUserOrLoginState(ctx, user.GetName())
	if err != nil {
		return nil, trace.Wrap(err)
	}

	diagCtx.Info.Success = true
	return s.makeAuthResponse(ctx, req, userState, identity, params.SessionTTL)
}

// exchangeAndVerify swaps the authorization code for tokens and verifies the
// resulting ID token.
//
// Verification is delegated to lib/oidc's caching validator, which fetches the
// provider's JWKS (handling key rotation) and checks signature, issuer,
// audience and expiry. The nonce is bound here.
func (s *Service) exchangeAndVerify(ctx context.Context, connector types.OIDCConnector, req *types.OIDCAuthRequest, code string) (*googleClaims, error) {
	redirectURL, err := services.GetRedirectURL(connector, req.ProxyAddress)
	if err != nil {
		return nil, trace.Wrap(err)
	}
	oauthConfig, err := s.oauthConfig(ctx, connector, redirectURL)
	if err != nil {
		return nil, trace.Wrap(err)
	}

	exchangeCtx := context.WithValue(ctx, oauth2.HTTPClient, s.cfg.HTTPClient)
	token, err := oauthConfig.Exchange(exchangeCtx, code, oauth2.VerifierOption(req.PkceVerifier))
	if err != nil {
		return nil, trace.Wrap(err, "Requesting Google OAuth2 token failed.")
	}

	rawIDToken, ok := token.Extra("id_token").(string)
	if !ok || rawIDToken == "" {
		return nil, trace.AccessDenied("Google token response did not contain an ID token.")
	}

	validator, err := s.validator.GetValidator(ctx, connector.GetIssuerURL(), connector.GetClientID())
	if err != nil {
		return nil, trace.Wrap(err)
	}

	// The nonce is bound to the state token that this callback presented. Note
	// that the underlying verifier checks the nonce unconditionally (its default
	// expectation is the empty string), so this option is required, not
	// optional: omitting it would reject every real Google token rather than
	// silently skip the check.
	expectedNonce := NonceForStateToken(req.StateToken)
	claims, err := validator.ValidateToken(ctx, rawIDToken,
		rp.WithNonce(func(context.Context) string {
			return expectedNonce
		}),
		rp.WithSupportedSigningAlgorithms(s.signingAlgs...),
	)
	if err != nil {
		return nil, trace.AccessDenied("Google ID token verification failed: %v", err)
	}

	return claims, nil
}

// checkClaims applies this deployment's authorization policy to a verified ID
// token.
func (s *Service) checkClaims(claims *googleClaims) error {
	// The hosted domain check.
	//
	// A personal Gmail account carries NO "hd" claim at all, so an absent claim
	// must be an explicit reject. If this were written as
	// "if hd != "" && hd != domain" then every personal Gmail account in the
	// world would be admitted.
	if claims.HostedDomain == "" {
		return unauthorizedf("Google account %q has no hosted domain (hd) claim; only %s Workspace accounts may log in",
			claims.Email, s.hostedDomain)
	}
	if !isASCII(claims.HostedDomain) || strings.ToLower(claims.HostedDomain) != s.hostedDomain {
		return unauthorizedf("Google account %q belongs to hosted domain %q, not %q",
			claims.Email, claims.HostedDomain, s.hostedDomain)
	}

	// NOTE: the domain is never derived from the email claim. Do not "simplify"
	// the check above into a suffix match on claims.Email: an attacker who
	// controls example.com.evil.net can then mint addresses that pass.

	if !bool(claims.EmailVerified) {
		return unauthorizedf("Google account %q has an unverified email address", claims.Email)
	}
	if claims.Email == "" {
		return trace.AccessDenied("Google ID token has no email claim")
	}
	// Defence in depth: the verifier already rejects a token with no "sub"
	// (zoidc.CheckSubject), but the subject becomes the user's immutable
	// identifier, so do not rely on a library detail for that.
	if claims.Subject == "" {
		return trace.AccessDenied("Google ID token has no subject claim")
	}
	return nil
}

// createUserParams holds everything needed to create or update the Teleport
// user for an authenticated Google identity.
type createUserParams struct {
	ConnectorName string
	Username      string
	// UserID is the Google "sub" claim: a stable, immutable identifier for the
	// account. Unlike the email address it is never reassigned.
	UserID     string
	Roles      []string
	Traits     map[string][]string
	SessionTTL time.Duration
}

func (s *Service) calculateUser(ctx context.Context, diagCtx *auth.SSODiagContext, connector types.OIDCConnector, claims *googleClaims, req *types.OIDCAuthRequest) (*createUserParams, error) {
	username, err := claims.username(connector.GetUsernameClaim())
	if err != nil {
		return nil, trace.Wrap(err)
	}

	p := createUserParams{
		ConnectorName: connector.GetName(),
		Username:      username,
		UserID:        claims.Subject,
		Traits:        claims.traits(username, s.hostedDomain),
	}
	diagCtx.Info.OIDCTraitsFromClaims = p.Traits

	warnings, roles := services.TraitsToRoles(connector.GetTraitMappings(), p.Traits)
	if len(warnings) > 0 {
		diagCtx.Info.OIDCClaimsToRolesWarnings = &types.SSOWarnings{
			Message:  "Some claims-to-roles rules did not match",
			Warnings: warnings,
		}
		s.cfg.Logger.WarnContext(ctx, "Unmatched claims-to-roles rules", "warnings", warnings)
	}
	if len(roles) == 0 {
		return nil, unauthorizedf("no roles mapped for user %q; check the connector's claims_to_roles", username)
	}
	p.Roles = roles

	evaluationOutput, err := s.cfg.Auth.GetLoginRuleEvaluator().Evaluate(ctx, &loginrule.EvaluationInput{
		Traits: p.Traits,
	})
	if err != nil {
		return nil, trace.Wrap(err)
	}
	p.Traits = evaluationOutput.Traits
	diagCtx.Info.AppliedLoginRules = evaluationOutput.AppliedRules

	// Pick the smaller of the role-derived TTL and the requested TTL.
	roleSet, err := services.FetchRolesWithContext(p.Roles, s.cfg.Auth, services.RoleTemplateContext{
		Username: p.Username,
		Traits:   p.Traits,
	})
	if err != nil {
		return nil, trace.Wrap(err)
	}
	roleTTL := roleSet.AdjustSessionTTL(apidefaults.MaxCertDuration)
	p.SessionTTL = utils.MinTTL(roleTTL, req.CertTTL)

	return &p, nil
}

// createUser creates or updates the Teleport user for a Google identity.
//
// This reimplements the collision guard from lib/auth.(*Server).createGithubUser
// (that method is unexported, so it cannot be reused). The guard is what stops a
// Google identity whose derived username happens to match an existing local
// account -- say a local "admin" -- from taking that account over: if the
// existing user was not created by this same connector, we refuse.
//
// dryRun is set for SSOTestFlow. In that case nothing is written to the backend.
func (s *Service) createUser(ctx context.Context, p *createUserParams, dryRun bool) (types.User, error) {
	expires := s.cfg.Clock.Now().UTC().Add(p.SessionTTL)

	user := &types.UserV2{
		Kind:    types.KindUser,
		Version: types.V2,
		Metadata: types.Metadata{
			Name:      p.Username,
			Namespace: apidefaults.Namespace,
			Expires:   &expires,
		},
		Spec: types.UserSpecV2{
			Roles:  p.Roles,
			Traits: p.Traits,
			OIDCIdentities: []types.ExternalIdentity{{
				ConnectorID: p.ConnectorName,
				Username:    p.Username,
				UserID:      p.UserID,
			}},
			CreatedBy: types.CreatedBy{
				User: types.UserRef{Name: teleport.UserSystem},
				Time: s.cfg.Clock.Now().UTC(),
				Connector: &types.ConnectorRef{
					Type:     constants.OIDC,
					ID:       p.ConnectorName,
					Identity: p.Username,
				},
			},
		},
	}

	// Run Teleport's own resource validation before writing. The username comes
	// from a claim, and although it is a Google-issued email address rather
	// than free text, a name that Teleport considers malformed or reserved must
	// not reach the backend.
	if err := user.CheckAndSetDefaults(); err != nil {
		return nil, trace.Wrap(err, "invalid user derived from Google identity")
	}

	if dryRun {
		return user, nil
	}

	existingUser, err := s.cfg.Auth.GetUser(ctx, p.Username, false)
	if err != nil && !trace.IsNotFound(err) {
		return nil, trace.Wrap(err)
	}

	if existingUser != nil {
		ref := user.GetCreatedBy().Connector
		if !ref.IsSameProvider(existingUser.GetCreatedBy().Connector) {
			return nil, trace.AlreadyExists("user %q already exists and was not created by the %q OIDC connector",
				existingUser.GetName(), p.ConnectorName)
		}

		// Second guard, beyond the one createGithubUser has: the existing user
		// must be the same Google account, not merely an account with the same
		// address.
		//
		// Google's "sub" claim is immutable and never reused; an email address
		// is not. If alice@ leaves and a Workspace administrator later creates
		// a new alice@ for a different person, that person would otherwise
		// silently inherit the previous alice's Teleport user, roles and
		// traits. Refuse instead, and let an administrator delete the stale
		// user deliberately.
		for _, existing := range existingUser.GetOIDCIdentities() {
			if existing.ConnectorID == p.ConnectorName && existing.UserID != "" && existing.UserID != p.UserID {
				return nil, trace.AlreadyExists(
					"user %q already exists for a different Google account (subject %q, not %q); remove the stale user before this account can log in",
					existingUser.GetName(), existing.UserID, p.UserID)
			}
		}

		user.SetRevision(existingUser.GetRevision())
		if _, err := s.cfg.Auth.UpdateUser(ctx, user); err != nil {
			return nil, trace.Wrap(err)
		}
		return user, nil
	}

	if _, err := s.cfg.Auth.CreateUser(ctx, user); err != nil {
		return nil, trace.Wrap(err)
	}
	return user, nil
}

// makeAuthResponse mirrors lib/auth.(*Server).makeGithubAuthResponse.
func (s *Service) makeAuthResponse(
	ctx context.Context,
	req *types.OIDCAuthRequest,
	userState services.UserState,
	identity types.ExternalIdentity,
	sessionTTL time.Duration,
) (*authclient.OIDCAuthResponse, error) {
	resp := authclient.OIDCAuthResponse{
		Req:      oidcAuthRequestFromProto(req),
		Identity: identity,
		Username: userState.GetName(),
	}

	// Browser flow: create a web session.
	if req.CreateWebSession {
		session, err := s.cfg.Auth.CreateWebSessionFromReq(ctx, auth.NewWebSessionRequest{
			User:                 userState.GetName(),
			Roles:                userState.GetRoles(),
			Traits:               userState.GetTraits(),
			SessionTTL:           sessionTTL,
			LoginTime:            s.cfg.Clock.Now().UTC(),
			LoginIP:              req.ClientLoginIP,
			LoginUserAgent:       req.ClientUserAgent,
			AttestWebSession:     true,
			CreateDeviceWebToken: true,
			Scope:                req.Scope,
		})
		if err != nil {
			return nil, trace.Wrap(err, "Failed to create web session.")
		}
		resp.Session = session
	}

	// Console flow: sign the client's public keys.
	if len(req.SshPublicKey) != 0 || len(req.TlsPublicKey) != 0 {
		sshCert, tlsCert, err := s.cfg.Auth.CreateSessionCerts(ctx, &auth.SessionCertsRequest{
			UserState:               userState,
			SessionTTL:              sessionTTL,
			SSHPubKey:               req.SshPublicKey,
			TLSPubKey:               req.TlsPublicKey,
			SSHAttestationStatement: hardwarekey.AttestationStatementFromProto(req.SshAttestationStatement),
			TLSAttestationStatement: hardwarekey.AttestationStatementFromProto(req.TlsAttestationStatement),
			Compatibility:           req.Compatibility,
			RouteToCluster:          req.RouteToCluster,
			KubernetesCluster:       req.KubernetesCluster,
			LoginIP:                 req.ClientLoginIP,
			Scope:                   req.Scope,
		})
		if err != nil {
			return nil, trace.Wrap(err, "Failed to create session certificate.")
		}

		clusterName, err := s.cfg.Auth.GetClusterName(ctx)
		if err != nil {
			return nil, trace.Wrap(err, "Failed to obtain cluster name.")
		}

		resp.Cert = sshCert
		resp.TLSCert = tlsCert

		// Return the host CA for this cluster only.
		authority, err := s.cfg.Auth.GetCertAuthority(ctx, types.CertAuthID{
			Type:       types.HostCA,
			DomainName: clusterName.GetClusterName(),
		}, false)
		if err != nil {
			return nil, trace.Wrap(err, "Failed to obtain cluster's host CA.")
		}
		resp.HostSigners = append(resp.HostSigners, authority)
	}

	if o, err := s.cfg.Auth.ClientOptionsForLogin(userState); err == nil {
		resp.ClientOptions = o
	} else {
		s.cfg.Logger.WarnContext(ctx, "Failed to calculate client options for Google OIDC login",
			"username", userState.GetName(), "error", err)
	}

	return &resp, nil
}

func oidcAuthRequestFromProto(req *types.OIDCAuthRequest) authclient.OIDCAuthRequest {
	return authclient.OIDCAuthRequest{
		ConnectorID:       req.ConnectorID,
		CSRFToken:         req.CSRFToken,
		SSHPubKey:         req.SshPublicKey,
		TLSPubKey:         req.TlsPublicKey,
		CreateWebSession:  req.CreateWebSession,
		ClientRedirectURL: req.ClientRedirectURL,
	}
}

// Compile-time assertions. [Identity] is satisfied by *auth.Services thanks to
// Slice 1's DeleteOIDCAuthRequest; Slice 4 wires the two together.
var (
	_ auth.OIDCService = (*Service)(nil)
	_ AuthService      = (*auth.Server)(nil)
	_ Identity         = (*auth.Services)(nil)
)
