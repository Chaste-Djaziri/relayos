import threading
import time

import pytest

from laptop_bridge import state


@pytest.fixture(autouse=True)
def isolated_state(tmp_path, monkeypatch):
    monkeypatch.setattr(state, "STATE_DIR", tmp_path)
    monkeypatch.setattr(state, "DATABASE_FILE", tmp_path / "state.sqlite3")


def create_request():
    return state.request("run_command", {"target": "version", "argv": ["tool", "--version"]})


def test_approval_is_single_use():
    token = create_request()
    state.approve(token)
    assert state.consume(token)["details"]["target"] == "version"
    with pytest.raises(PermissionError):
        state.consume(token)


def test_deny_and_expiry_are_terminal(monkeypatch):
    token = create_request()
    state.deny(token)
    with pytest.raises(PermissionError):
        state.consume(token)
    token = create_request()
    current_time = time.time()
    monkeypatch.setattr(state.time, "time", lambda: current_time + state.TTL + 1)
    assert state.pending_requests() == []


def test_emergency_stop_blocks_approved_action():
    token = create_request()
    state.approve(token)
    state.set_emergency_stop(True)
    with pytest.raises(PermissionError, match="Emergency stop"):
        state.consume(token)


def test_concurrent_consumers_get_one_action():
    token = create_request()
    state.approve(token)
    results = []

    def consume():
        try:
            state.consume(token)
            results.append("ok")
        except PermissionError:
            results.append("denied")

    workers = [threading.Thread(target=consume) for _ in range(2)]
    for worker in workers:
        worker.start()
    for worker in workers:
        worker.join()
    assert sorted(results) == ["denied", "ok"]


def test_history_contains_metadata_not_argv_and_purges_old_entries():
    state.record_result("run_command", "version", exit_code=0, duration_ms=12)
    history = state.recent_history()
    assert history[0]["target"] == "version"
    assert "argv" not in history[0]
    with state._db() as connection:
        connection.execute("UPDATE action_history SET recorded_at = 0")
    state.record_result("open_app", "editor")
    assert len(state.recent_history()) == 1
