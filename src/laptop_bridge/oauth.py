"""Local-approval OAuth provider for ChatGPT, Claude, Gemini, and MCP clients."""
from __future__ import annotations

import json
from urllib.parse import parse_qsl, urlencode, urlparse, urlunparse

from mcp.server.auth.provider import AccessToken, AuthorizationCode, AuthorizationParams, AuthorizeError, RefreshToken, RegistrationError
from mcp.shared.auth import OAuthClientInformationFull, OAuthToken

from . import state

SCOPE = "mcp"


def _safe_redirect(url: str) -> bool:
    """Allow public HTTPS callbacks and Claude Code's loopback callback.

    Claude.ai uses its HTTPS callback, while Claude Code uses a local
    ephemeral callback. Loopback is restricted to localhost/127.0.0.1 and
    never permits credentials or a non-loopback hostname.
    """
    parsed = urlparse(url)
    if not parsed.hostname or parsed.username is not None or parsed.password is not None:
        return False
    if parsed.scheme == "https":
        return True
    return parsed.scheme == "http" and parsed.hostname in {"localhost", "127.0.0.1"}


class LocalApprovalOAuthProvider:
    """OAuth authorization server that requires an in-person companion approval."""

    def __init__(self, public_base_url: str):
        self.public_base_url = public_base_url.rstrip("/")

    async def get_client(self, client_id: str):
        data = state.oauth_client(client_id)
        return OAuthClientInformationFull.model_validate(data) if data else None

    async def register_client(self, client_info):
        redirects = [str(url) for url in client_info.redirect_uris or []]
        if not redirects or not all(_safe_redirect(url) for url in redirects):
            raise RegistrationError("invalid_redirect_uri", "Only HTTPS callback URLs are allowed")
        if client_info.scope not in (None, SCOPE):
            raise RegistrationError("invalid_client_metadata", "Only the mcp scope is supported")
        if not {"authorization_code", "refresh_token"}.issuperset(set(client_info.grant_types)):
            raise RegistrationError("invalid_client_metadata", "Only authorization_code and refresh_token grants are supported")
        # Gemini is a public client; PKCE is required by the authorization endpoint.
        client_info.token_endpoint_auth_method = "none"
        client_info.client_secret = None
        client_info.client_secret_expires_at = None
        client_info.scope = SCOPE
        state.oauth_register_client(client_info.client_id, client_info.model_dump(mode="json"))

    async def authorize(self, client, params: AuthorizationParams):
        if not _safe_redirect(str(params.redirect_uri)):
            raise AuthorizeError("unauthorized_client", "The redirect URI must use HTTPS or Claude Code localhost")
        if params.resource not in (None, f"{self.public_base_url}/mcp"):
            raise AuthorizeError("invalid_target", "The resource must be this MCP endpoint")
        scopes = params.scopes or [SCOPE]
        if scopes != [SCOPE]:
            raise AuthorizeError("invalid_scope", "Only the mcp scope is supported")
        request_id = state.create_oauth_authorization(
            client.client_id, str(params.redirect_uri), params.state, scopes, params.code_challenge, params.resource
        )
        return f"{self.public_base_url}/oauth/approval/{request_id}"

    async def load_authorization_code(self, client, authorization_code: str):
        row = state.oauth_load_code(authorization_code)
        if not row:
            return None
        return AuthorizationCode(
            code=authorization_code,
            client_id=row["client_id"],
            scopes=json.loads(row["scopes_json"]),
            expires_at=row["expires_at"],
            code_challenge=row["code_challenge"],
            redirect_uri=row["redirect_uri"],
            redirect_uri_provided_explicitly=True,
            resource=row["resource"],
        )

    async def exchange_authorization_code(self, client, authorization_code):
        issued = state.oauth_consume_code_and_issue_tokens(authorization_code.code)
        if not issued:
            from mcp.server.auth.provider import TokenError
            raise TokenError("invalid_grant", "Authorization code has already been used")
        return OAuthToken(
            access_token=issued["access_token"], token_type="Bearer", expires_in=state.OAUTH_ACCESS_TOKEN_TTL,
            refresh_token=issued["refresh_token"], scope=" ".join(issued["scopes"]),
        )

    async def load_refresh_token(self, client, refresh_token: str):
        row = state.oauth_load_token(refresh_token, "refresh")
        if not row:
            return None
        return RefreshToken(token=refresh_token, client_id=row["client_id"], scopes=json.loads(row["scopes_json"]), expires_at=int(row["expires_at"]), resource=row["resource"])

    async def exchange_refresh_token(self, client, refresh_token, scopes):
        issued = state.oauth_rotate_refresh_token(refresh_token.token, scopes)
        if not issued:
            from mcp.server.auth.provider import TokenError
            raise TokenError("invalid_grant", "Refresh token has been revoked")
        return OAuthToken(access_token=issued["access_token"], token_type="Bearer", expires_in=state.OAUTH_ACCESS_TOKEN_TTL, refresh_token=issued["refresh_token"], scope=" ".join(scopes))

    async def load_access_token(self, token: str):
        row = state.oauth_load_token(token, "access")
        if not row:
            return None
        return AccessToken(token=token, client_id=row["client_id"], scopes=json.loads(row["scopes_json"]), expires_at=int(row["expires_at"]), resource=row["resource"])

    async def verify_token(self, token: str):
        """Implement the MCP token-verifier protocol for the resource server."""
        return await self.load_access_token(token)

    async def revoke_token(self, token):
        row = state.oauth_load_token(token.token, "access") or state.oauth_load_token(token.token, "refresh")
        if row:
            state.revoke_oauth_grant(row["grant_id"])


def approval_redirect(result, issuer: str | None = None):
    """Build the client callback without losing existing query or fragments.

    ChatGPT callbacks are opaque HTTPS URLs and may already contain query
    parameters. Constructing the URL by string concatenation can put OAuth
    data after a fragment, which browsers never send to the server and which
    the connector reports as missing callback data.
    """
    parsed = urlparse(result["redirect_uri"])
    query = parse_qsl(parsed.query, keep_blank_values=True)
    query.extend(
        (key, value)
        for key, value in (
            ("code", result.get("code")),
            ("state", result.get("state")),
            ("iss", issuer.rstrip("/") if issuer else result.get("iss")),
        )
        if value is not None
    )
    return urlunparse(parsed._replace(query=urlencode(query), fragment=""))
