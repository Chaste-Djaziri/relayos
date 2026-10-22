import time

import pytest

from laptop_bridge import state


def test_guidance_session_lifecycle_and_single_active(tmp_path, monkeypatch):
    db = tmp_path / "state.sqlite3"
    monkeypatch.setattr(state, "DATABASE_FILE", db)
    monkeypatch.setattr(state, "STATE_DIR", tmp_path)
    session = state.start_guidance_session(900)
    assert session["active"] is True
    assert session["expires_at"] - session["created_at"] == pytest.approx(900, abs=1)
    with pytest.raises(PermissionError):
        state.start_guidance_session(60)
    assert state.guidance_session_status(session["session_id"])["active"] is True
    assert state.stop_guidance_session(session["session_id"]) is True
    assert state.guidance_session_status(session["session_id"])["active"] is False


def test_guidance_session_click_metadata_is_queued_and_consumed(tmp_path, monkeypatch):
    db = tmp_path / "state.sqlite3"
    monkeypatch.setattr(state, "DATABASE_FILE", db)
    monkeypatch.setattr(state, "STATE_DIR", tmp_path)
    session = state.start_guidance_session(900)
    token = session["session_id"]
    assert state.queue_guidance_click(token, 1, 22.5, 44.0, "left", ["shift"], 123.0)
    events = state.get_guidance_clicks(token)
    assert events == [{"event_id": 1, "display_id": 1, "x": 22.5, "y": 44.0, "button": "left", "modifiers": ["shift"], "occurred_at": 123.0}]
    assert state.get_guidance_clicks(token) == []


def test_guidance_session_expires(tmp_path, monkeypatch):
    db = tmp_path / "state.sqlite3"
    monkeypatch.setattr(state, "DATABASE_FILE", db)
    monkeypatch.setattr(state, "STATE_DIR", tmp_path)
    session = state.start_guidance_session(1)
    time.sleep(1.05)
    assert state.guidance_session_status(session["session_id"])["active"] is False
    assert state.queue_guidance_click(session["session_id"], 0, 1, 2) is False
