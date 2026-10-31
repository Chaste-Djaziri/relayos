# Path: tests/test_approvals_cli.py
"""Tests for the local approval-helper command grant operations."""
import json
import sys
import pytest
from laptop_bridge import approvals, state

@pytest.fixture(autouse=True)
def isolated_state(tmp_path, monkeypatch):
    monkeypatch.setattr(state, "STATE_DIR", tmp_path)
    monkeypatch.setattr(state, "DATABASE_FILE", tmp_path / "state.sqlite3")

def call(monkeypatch, capsys, *args):
    monkeypatch.setattr(sys, "argv", ["relayos-approvals", *args])
    approvals.main()
    return json.loads(capsys.readouterr().out)

def test_list_and_revoke(monkeypatch, capsys, tmp_path):
    root = str(tmp_path)
    token = state.grant_project_command(
        root, "/usr/bin/git", ["git", "commit", "-m", "initial"],
        root, "always", scope_prefix=["git", "commit"])
    grants = call(monkeypatch, capsys, "list-command-grants")
    assert len(grants) == 1
    assert grants[0]["token"] == token
    assert grants[0]["scope_prefix"] == ["git", "commit"]
    assert grants[0]["grant_type"] == "always"
    assert call(monkeypatch, capsys, "revoke-command-grant", token)["revoked"]
    assert call(monkeypatch, capsys, "list-command-grants") == []
    assert not state.has_saved_command_grant(
        root, "/usr/bin/git", ["git", "commit", "-m", "next"], root)

def test_unknown_revoke_rejected(monkeypatch, capsys):
    with pytest.raises(ValueError, match="not found"):
        call(monkeypatch, capsys, "revoke-command-grant", "missing")


def test_duplicate_exact_grants_can_be_previewed_and_cleaned_without_losing_access(
    monkeypatch, capsys, tmp_path
):
    root = str(tmp_path)
    argv = ["git", "commit", "-m", "private message"]
    first = state.grant_project_command(root, "/usr/bin/git", argv, root, "always")
    # New approvals for the same scope are idempotent.
    assert state.grant_project_command(root, "/usr/bin/git", argv, root, "always") == first
    distinct = state.grant_project_command(
        root, "/usr/bin/git", ["git", "commit", "-m", "different"], root, "always"
    )
    assert distinct != first

    # Simulate duplicates saved by an older app without altering live user data.
    with state._db() as db:
        db.execute(
            """INSERT INTO command_grants
                (token, project_root, executable, argv_digest, working_directory,
                 grant_type, created_at)
                SELECT 'older-copy', project_root, executable, argv_digest,
                       working_directory, grant_type, created_at - 10
                FROM command_grants WHERE token = ?""",
            (first,),
        )

    assert call(monkeypatch, capsys, "command-grant-duplicates") == {
        "total": 3, "duplicates": 1
    }
    cleaned = call(monkeypatch, capsys, "cleanup-command-grant-duplicates")
    assert cleaned == {"removed": 1}
    assert call(monkeypatch, capsys, "cleanup-command-grant-duplicates") == {"removed": 0}
    grants = call(monkeypatch, capsys, "list-command-grants")
    assert len(grants) == 2
    assert all(g["scope_fingerprint"] for g in grants)
    assert all("argv_digest" not in g and "session_token" not in g for g in grants)
    assert state.has_saved_command_grant(root, "/usr/bin/git", argv, root)
    assert state.has_saved_command_grant(
        root, "/usr/bin/git", ["git", "commit", "-m", "different"], root
    )


def test_cleanup_keeps_session_and_persistent_and_distinct_working_directories(
    monkeypatch, capsys, tmp_path
):
    root = str(tmp_path)
    argv = ["git", "add", "--", "one"]
    state.grant_project_command(root, "/usr/bin/git", argv, root, "always")
    state.grant_project_command(root, "/usr/bin/git", argv, root, "session", session_id="session-one")
    state.grant_project_command(root, "/usr/bin/git", argv, root, "session", session_id="session-two")
    state.grant_project_command(root, "/usr/bin/git", argv, root + "/sub", "always")
    assert call(monkeypatch, capsys, "command-grant-duplicates")["duplicates"] == 0
    assert call(monkeypatch, capsys, "cleanup-command-grant-duplicates")["removed"] == 0


def test_repeated_prefix_grant_is_idempotent_and_once_grants_stay_unique(tmp_path):
    root = str(tmp_path)
    argv = ["git", "commit", "-m", "one"]
    options = dict(grant_type="always", scope_prefix=["git", "commit"])
    first = state.grant_project_command(root, "/usr/bin/git", argv, root, **options)
    second = state.grant_project_command(
        root, "/usr/bin/git", ["git", "commit", "-m", "another"], root, **options
    )
    assert second == first
    assert len(state.saved_command_grants()) == 1
    token_a = state.grant_project_command(root, "/usr/bin/git", argv, root, "once")
    token_b = state.grant_project_command(root, "/usr/bin/git", argv, root, "once")
    assert token_a != token_b


def test_inbox_queues_multiple_independent_requests_and_persists_audit(monkeypatch, capsys):
    first = state.request("project_command", {
        "target": "/tmp/project:/usr/bin/git", "argv": ["git", "commit", "-m", "test"],
        "context": {"cwd": "/tmp/project", "scope_prefix": ["git", "commit"]},
    })
    second = state.request("project_session", {
        "target": "/tmp/other-project", "argv": [],
    })
    inbox = call(monkeypatch, capsys, "list-inbox")
    assert {item["request_id"] for item in inbox} == {first, second}
    assert inbox[0]["expires_at"] > inbox[0]["created_at"]
    assert call(monkeypatch, capsys, "decide-inbox", first, "session")["decision"] == "session"
    remaining = call(monkeypatch, capsys, "list-inbox")
    assert [item["request_id"] for item in remaining] == [second]
    call(monkeypatch, capsys, "decide-inbox", second, "deny")
    history = call(monkeypatch, capsys, "activity-history", "--search", "project_command")
    assert any(item["decision"] == "approved" for item in history)
    assert "argv_json" not in str(history)
    with pytest.raises(PermissionError, match="decided or expired"):
        call(monkeypatch, capsys, "decide-inbox", first, "persistent")


def test_expired_and_emergency_stopped_inbox_requests_cannot_be_approved(
    monkeypatch, capsys
):
    import time
    expired = state.request("project_command", {"target": "/tmp/p:/usr/bin/git", "argv": []})
    with state._db() as db:
        db.execute(
            "UPDATE requests SET created_at = ? WHERE token = ?",
            (time.time() - state.TTL - 5, expired),
        )
    assert call(monkeypatch, capsys, "list-inbox") == []
    with pytest.raises(PermissionError):
        call(monkeypatch, capsys, "decide-inbox", expired, "once")
    current = state.request("project_command", {"target": "/tmp/p:/usr/bin/git", "argv": []})
    state.set_emergency_stop(True)
    with pytest.raises(PermissionError):
        call(monkeypatch, capsys, "decide-inbox", current, "once")


def test_oauth_inbox_restricts_decisions_and_records_client_name(monkeypatch, capsys):
    state.oauth_register_client("client-1", {"client_name": "Test Client"})
    req = state.create_oauth_authorization(
        "client-1", "https://example.org/callback", "csrf", ["mcp"],
        "challenge", None,
    )
    inbox = call(monkeypatch, capsys, "list-inbox")
    item = next(i for i in inbox if i["request_id"] == req)
    assert item["kind"] == "oauth_connection"
    assert item["target"] == "Test Client"
    assert "redirect_uri" not in item
    with pytest.raises(ValueError, match="Approve once"):
        call(monkeypatch, capsys, "decide-inbox", req, "persistent")
    assert call(monkeypatch, capsys, "decide-inbox", req, "once")["decision"] == "once"
    assert all(i["request_id"] != req for i in call(monkeypatch, capsys, "list-inbox"))
    with pytest.raises(PermissionError):
        call(monkeypatch, capsys, "decide-inbox", req, "deny")
