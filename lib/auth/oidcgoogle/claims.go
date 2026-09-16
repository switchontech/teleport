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
	"github.com/gravitational/trace"
	zoidc "github.com/zitadel/oidc/v3/pkg/oidc"

	"github.com/gravitational/teleport/api/constants"
	"github.com/gravitational/teleport/api/types"
)

// googleClaims are the ID token claims this service understands.
//
// It embeds [zoidc.TokenClaims] (iss/sub/aud/exp/nonce/...) and adds the Google
// specific claims. TokenClaims is used rather than zoidc.IDTokenClaims because
// IDTokenClaims defines its own UnmarshalJSON; embedding it would promote that
// method onto this struct and the fields declared below would silently never be
// populated. A silently empty "hd" would mean every login is rejected -- safe,
// but broken -- so the choice matters.
//
// The claim set is deliberately a fixed whitelist rather than a free-form map:
// only these claims can ever influence username derivation or role mapping.
type googleClaims struct {
	zoidc.TokenClaims

	// Email is the account's primary email address.
	Email string `json:"email"`
	// EmailVerified is Google's assertion that the address is verified.
	// zoidc.Bool tolerates providers that send this as the string "true";
	// Google sends a real JSON boolean. An absent claim decodes to false,
	// which is a reject.
	EmailVerified zoidc.Bool `json:"email_verified"`
	// HostedDomain is the "hd" claim: the Google Workspace domain that owns
	// this account. Personal Gmail accounts do NOT have this claim.
	HostedDomain string `json:"hd"`
	// Name, GivenName and FamilyName come from the "profile" scope and are
	// exposed as traits only.
	Name       string `json:"name"`
	GivenName  string `json:"given_name"`
	FamilyName string `json:"family_name"`
}

// username derives the Teleport username from the verified claims.
//
// The default claim is "email", which matches Teleport's own default for OIDC
// connectors. "sub" is offered because it is Google's stable, never-reused
// identifier; an email address can be deleted and later reassigned to a
// different person within the same Workspace.
//
// Arbitrary claims are NOT supported: allowing one would mean trusting a claim
// we have not reasoned about (for example "name", which a user can usually edit
// themselves, and which would let a user choose their own Teleport username).
func (c *googleClaims) username(usernameClaim string) (string, error) {
	switch usernameClaim {
	case "", "email":
		if c.Email == "" {
			return "", trace.AccessDenied("Google ID token has no email claim")
		}
		return c.Email, nil
	case "sub":
		if c.Subject == "" {
			return "", trace.AccessDenied("Google ID token has no subject claim")
		}
		return c.Subject, nil
	default:
		return "", trace.BadParameter("username_claim %q is not supported; use \"email\" or \"sub\"", usernameClaim)
	}
}

// traits converts the verified claims into Teleport traits for role mapping and
// role templating.
//
// hostedDomain is the configured (lower case) domain. The "hd" trait is set to
// that canonical value rather than to the raw claim. By the time this is
// called, checkClaims has already established that the two are equal ignoring
// ASCII case, so nothing is being asserted that the token did not say; using
// the canonical form just means a connector's claims_to_roles rule does not
// silently stop matching if Google ever changes the casing it emits.
func (c *googleClaims) traits(username, hostedDomain string) map[string][]string {
	traits := map[string][]string{
		constants.TraitLogins: {username},
		"sub":                 {c.Subject},
		"email":               {c.Email},
		"hd":                  {hostedDomain},
	}
	if c.Name != "" {
		traits["name"] = []string{c.Name}
	}
	if c.GivenName != "" {
		traits["given_name"] = []string{c.GivenName}
	}
	if c.FamilyName != "" {
		traits["family_name"] = []string{c.FamilyName}
	}
	return traits
}

// asOIDCClaims renders the claims for the SSO diagnostic record and the audit
// event's identity attributes.
func (c *googleClaims) asOIDCClaims() types.OIDCClaims {
	return types.OIDCClaims{
		"iss":            c.Issuer,
		"sub":            c.Subject,
		"email":          c.Email,
		"email_verified": bool(c.EmailVerified),
		"hd":             c.HostedDomain,
		"name":           c.Name,
	}
}
