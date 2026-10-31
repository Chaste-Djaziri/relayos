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
    # A ChatGPT approval may race the companion's fallback approval; both
    # surfaces can agree on the same pending request without duplicating it.
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


def test_decide_request_explicit_deny():
    token = create_request()
    assert state.decide_request(token, "deny") is True
    with pytest.raises(PermissionError):
        state.consume(token)
    with state._db() as conn:
        row = conn.execute("SELECT status FROM requests WHERE token = ?", (token,)).fetchone()
        assert row["status"] == "denied"
    # Further decide calls on a denied request return False
    assert state.decide_request(token, "once") is False


def test_approvals_cli_decide_request_deny(monkeypatch):
    from laptop_bridge import approvals
    token = create_request()
    monkeypatch.setattr("sys.argv", ["laptop-bridge-approvals", "decide-request", token, "deny"])
    approvals.main()
    with pytest.raises(PermissionError):
        state.consume(token)
    with state._db() as conn:
        row = conn.execute("SELECT status FROM requests WHERE token = ?", (token,)).fetchone()
        assert row["status"] == "denied"


def test_approvals_cli_direct_deny(monkeypatch):
    from laptop_bridge import approvals
    token = create_request()
    monkeypatch.setattr("sys.argv", ["laptop-bridge-approvals", "deny", token])
    approvals.main()
    with pytest.raises(PermissionError):
        state.consume(token)
    with state._db() as conn:
        row = conn.execute("SELECT status FROM requests WHERE token = ?", (token,)).fetchone()
        assert row["status"] == "denied"


def test_approvals_cli_emergency_stop_controls(monkeypatch, capsys):
    import json
    from laptop_bridge import approvals

    assert state.emergency_stop() is False

    monkeypatch.setattr("sys.argv", ["laptop-bridge-approvals", "set-emergency-stop", "true"])
    approvals.main()
    out = json.loads(capsys.readouterr().out)
    assert out["emergency_stop"] is True
    assert state.emergency_stop() is True

    monkeypatch.setattr("sys.argv", ["laptop-bridge-approvals", "emergency-stop-status"])
    approvals.main()
    out = json.loads(capsys.readouterr().out)
    assert out["emergency_stop"] is True

    monkeypatch.setattr("sys.argv", ["laptop-bridge-approvals", "set-emergency-stop", "false"])
    approvals.main()
    out = json.loads(capsys.readouterr().out)
    assert out["emergency_stop"] is False
    assert state.emergency_stop() is False


def test_emergency_stop_revokes_sessions_and_cancels_work():
    # Emergency stop must revoke active project sessions, desktop jobs, and guidance sessions
    with state._db() as conn:
        conn.execute("INSERT INTO project_sessions (token, root, created_at, expires_at, status) VALUES ('sess1', '/tmp', ?, ?, 'active')", (time.time(), time.time() + 3600))
        conn.execute("INSERT INTO desktop_jobs (token, kind, payload_json, created_at, status) VALUES ('job1', 'test', '{}', ?, 'pending')", (time.time(),))
        conn.execute("INSERT INTO guidance_sessions (token, created_at, expires_at, status) VALUES ('guide1', ?, ?, 'active')", (time.time(), time.time() + 900))
        conn.commit()

    state.set_emergency_stop(True)

    with state._db() as conn:
        sess = conn.execute("SELECT status FROM project_sessions WHERE token = 'sess1'").fetchone()
        assert sess["status"] == "revoked"
        job = conn.execute("SELECT status FROM desktop_jobs WHERE token = 'job1'").fetchone()
        assert job["status"] == "cancelled"
        guide = conn.execute("SELECT status FROM guidance_sessions WHERE token = 'guide1'").fetchone()
        assert guide["status"] == "stopped"

    with pytest.raises(PermissionError, match="Emergency stop is enabled"):
        state.project_session("sess1")


