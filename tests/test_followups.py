import time

import pytest

from laptop_bridge import server, state


@pytest.fixture(autouse=True)
def isolated_state(tmp_path, monkeypatch):
    monkeypatch.setattr(state, "STATE_DIR", tmp_path)
    monkeypatch.setattr(state, "DATABASE_FILE", tmp_path / "state.sqlite3")


def test_follow_up_lifecycle_and_metadata_only():
    token = server.record_follow_up_request(
        "Check the unfinished build",
        time.time() + 60,
        metadata={"project": "laptop-bridge"},
    )["follow_up_id"]
    pending = server.list_pending_follow_ups()
    assert pending[0]["follow_up_id"] == token
    assert pending[0]["metadata"] == {"project": "laptop-bridge"}
    server.complete_follow_up(token)
    assert server.list_pending_follow_ups() == []
    with pytest.raises(PermissionError):
        server.complete_follow_up(token)


def test_expired_follow_up_is_not_returned(monkeypatch):
    now = time.time()
    token = state.create_follow_up("expired", now - 30, expires_at=now - 1)
    assert token
    assert state.pending_follow_ups() == []
