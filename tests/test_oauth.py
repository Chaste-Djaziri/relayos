import asyncio

import pytest
from mcp.server.auth.provider import AuthorizationParams, AuthorizeError
from mcp.shared.auth import OAuthClientInformationFull

from laptop_bridge import state
from laptop_bridge.oauth import LocalApprovalOAuthProvider, approval_redirect


@pytest.fixture(autouse=True)
def isolated_state(tmp_path, monkeypatch):
    monkeypatch.setattr(state, "STATE_DIR", tmp_path)
    monkeypatch.setattr(state, "DATABASE_FILE", tmp_path / "state.sqlite3")


def run(coro):
    return asyncio.run(coro)


def client():
    return OAuthClientInformationFull(
        client_id="gemini-test", redirect_uris=["https://oauth-redirect.googleusercontent.com/r/gemini-test"],
        token_endpoint_auth_method="none", grant_types=["authorization_code", "refresh_token"], scope="mcp",
    )


def params():
    return AuthorizationParams(
        state="csrf", scopes=["mcp"], code_challenge="challenge", redirect_uri="https://oauth-redirect.googleusercontent.com/r/gemini-test",
        redirect_uri_provided_explicitly=True, resource="https://gemini-bridge.shangazi.rw/mcp",
    )


def test_local_approval_issues_single_use_code_and_rotating_tokens():
    provider = LocalApprovalOAuthProvider("https://gemini-bridge.shangazi.rw")
    registered = client()
    run(provider.register_client(registered))
    waiting_url = run(provider.authorize(registered, params()))
    request_id = waiting_url.rsplit("/", 1)[1]
    assert state.pending_oauth_authorizations()[0]["client_id"] == "gemini-test"
    state.decide_oauth_authorization(request_id, True)
    approved = state.consume_oauth_authorization(request_id)
    code = run(provider.load_authorization_code(registered, approved["code"]))
    tokens = run(provider.exchange_authorization_code(registered, code))
    assert run(provider.load_access_token(tokens.access_token)).client_id == "gemini-test"
    refreshed = run(provider.exchange_refresh_token(registered, run(provider.load_refresh_token(registered, tokens.refresh_token)), ["mcp"]))
    assert run(provider.load_access_token(tokens.access_token)) is None
    assert run(provider.load_access_token(refreshed.access_token)) is not None
    assert state.consume_oauth_authorization(request_id) is None


def test_google_callback_and_single_scope_are_required():
    provider = LocalApprovalOAuthProvider("https://gemini-bridge.shangazi.rw")
    bad = OAuthClientInformationFull(client_id="bad", redirect_uris=["http://example.com/callback"], token_endpoint_auth_method="none")
    with pytest.raises(Exception):
        run(provider.register_client(bad))
    registered = client()
    run(provider.register_client(registered))
    invalid = params().model_copy(update={"scopes": ["other"]})
    with pytest.raises(AuthorizeError):
        run(provider.authorize(registered, invalid))


def test_claude_https_callback_and_claude_code_loopback_callback_are_supported():
    provider = LocalApprovalOAuthProvider("https://relay.example.test")
    claude = OAuthClientInformationFull(
        client_id="claude-web", redirect_uris=["https://claude.ai/api/mcp/auth_callback"],
        token_endpoint_auth_method="none", grant_types=["authorization_code", "refresh_token"], scope="mcp",
    )
    run(provider.register_client(claude))
    web_params = params().model_copy(update={
        "redirect_uri": "https://claude.ai/api/mcp/auth_callback",
        "resource": "https://relay.example.test/mcp",
    })
    assert run(provider.authorize(claude, web_params)).startswith("https://relay.example.test/oauth/approval/")

    claude_code = claude.model_copy(update={"client_id": "claude-code", "redirect_uris": ["http://localhost:8088/callback"]})
    run(provider.register_client(claude_code))
    code_params = web_params.model_copy(update={"redirect_uri": "http://localhost:8088/callback"})
    assert run(provider.authorize(claude_code, code_params)).startswith("https://relay.example.test/oauth/approval/")


def test_emergency_stop_revokes_oauth_grants():
    provider = LocalApprovalOAuthProvider("https://gemini-bridge.shangazi.rw")
    registered = client()
    run(provider.register_client(registered))
    request_id = run(provider.authorize(registered, params())).rsplit("/", 1)[1]
    state.decide_oauth_authorization(request_id, True)
    code = state.consume_oauth_authorization(request_id)["code"]
    tokens = run(provider.exchange_authorization_code(registered, run(provider.load_authorization_code(registered, code))))
    state.set_emergency_stop(True)
    assert run(provider.load_access_token(tokens.access_token)) is None


def test_callback_data_survives_existing_query_and_fragment():
    callback = approval_redirect({
        "redirect_uri": "https://chatgpt.com/connector/oauth/callback?client=relay#ignored",
        "code": "one-time-code",
        "state": "chatgpt-state",
    })
    assert callback == "https://chatgpt.com/connector/oauth/callback?client=relay&code=one-time-code&state=chatgpt-state"
