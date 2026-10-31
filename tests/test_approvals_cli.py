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
