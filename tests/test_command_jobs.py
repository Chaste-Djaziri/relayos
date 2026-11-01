# Path: tests/test_command_jobs.py
import sys
import time

import pytest

from laptop_bridge import command_jobs, server, state


@pytest.fixture(autouse=True)
def isolated_jobs(tmp_path, monkeypatch):
    root = tmp_path / "state"
    root.mkdir()
    monkeypatch.setattr(state, "STATE_DIR", root)
    monkeypatch.setattr(state, "DATABASE_FILE", root / "state.sqlite3")
    monkeypatch.setattr(command_jobs, "manager", command_jobs.CommandJobManager(timeout=5, poll=0.02))


def session(tmp_path):
    project = tmp_path / "project"
    project.mkdir(parents=True)
    permission = state.request("project_session", {"target": str(project), "argv": []})
    state.approve(permission)
    return state.activate_project_session(permission)["session_id"], project


def wait_for(job_id, statuses=("completed", "failed", "cancelled", "timed_out", "output_limit")):
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        result = state.command_job(job_id)
        if result["status"] in statuses:
            return result
        time.sleep(0.025)
    raise AssertionError(f"Job did not finish: {state.command_job(job_id)}")


def approve_once(sid, project, argv):
    executable = server._resolve_executable(argv[0], project)
    return state.grant_project_command(
        str(project), executable, argv, str(project), "once", session_id=sid
    )


def test_job_denied_until_locally_approved_and_token_single_use(tmp_path):
    sid, project = session(tmp_path)
    argv = [sys.executable, "-c", "print('safe')"]
    assert server.start_project_command_job(sid, argv)["requires_authorization"]
    token = approve_once(sid, project, argv)
    started = server.start_project_command_job(sid, argv, authorization_token=token)
    assert started["started"]
    assert server.start_project_command_job(sid, argv, authorization_token=token)["requires_authorization"]
    finished = wait_for(started["job_id"])
    assert finished["status"] == "completed"
    result = server.read_project_command_job(sid, started["job_id"])
    assert "safe" in result["stdout"]
    assert "argv" not in result
    assert "command_job" in {entry["kind"] for entry in state.approval_activity()}


def test_job_incremental_output_and_session_isolation(tmp_path):
    sid, project = session(tmp_path)
    argv = [sys.executable, "-u", "-c",
            "import time;print('first',flush=True);time.sleep(.5);print('second',flush=True)"]
    token = approve_once(sid, project, argv)
    job_id = server.start_project_command_job(sid, argv, authorization_token=token)["job_id"]
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        snapshot = server.read_project_command_job(sid, job_id)
        if "first" in snapshot["stdout"]:
            break
        time.sleep(0.02)
    else:
        raise AssertionError("Did not get incremental stdout")
    offset = snapshot["stdout_offset"]
    assert snapshot["status"] in ("running", "completed")
    assert wait_for(job_id)["status"] == "completed"
    final = server.read_project_command_job(sid, job_id, stdout_offset=offset)
    assert "second" in final["stdout"]
    assert final["stdout_offset"] > offset

    other, _ = session(tmp_path / "different")
    with pytest.raises(PermissionError):
        server.read_project_command_job(other, job_id)
    with pytest.raises(PermissionError):
        server.cancel_project_command_job(other, job_id)


def test_job_cancellation_kills_approved_child(tmp_path):
    sid, project = session(tmp_path)
    argv = [sys.executable, "-u", "-c", "import time;print('begun',flush=True);time.sleep(30)"]
    token = approve_once(sid, project, argv)
    job_id = server.start_project_command_job(sid, argv, authorization_token=token)["job_id"]
    assert server.cancel_project_command_job(sid, job_id)["cancellation_requested"]
    assert wait_for(job_id)["status"] == "cancelled"
    assert state.command_job(job_id)["cancel_requested"] == 1


def test_emergency_stop_and_orphan_marking(tmp_path):
    sid, project = session(tmp_path)
    argv = [sys.executable, "-c", "import time;time.sleep(30)"]
    token = approve_once(sid, project, argv)
    job_id = server.start_project_command_job(sid, argv, authorization_token=token)["job_id"]
    state.set_emergency_stop(True)
    assert wait_for(job_id)["status"] == "cancelled"
    state.set_emergency_stop(False)
    queued = state.create_command_job(sid, str(project), str(project), "python")
    assert state.interrupt_orphan_command_jobs() == 1
    assert state.command_job(queued)["status"] == "interrupted"


def test_output_offset_validation(tmp_path):
    sid, project = session(tmp_path)
    argv = [sys.executable, "-c", "print('ok')"]
    token = approve_once(sid, project, argv)
    job_id = server.start_project_command_job(sid, argv, authorization_token=token)["job_id"]
    wait_for(job_id)
    with pytest.raises(ValueError):
        server.read_project_command_job(sid, job_id, stdout_offset=-1)


def test_local_helper_lists_and_cancels_jobs(tmp_path, monkeypatch, capsys):
    import json
    from laptop_bridge import approvals

    sid, project = session(tmp_path)
    job_id = state.create_command_job(sid, str(project), str(project), "python")

    def call(*args):
        monkeypatch.setattr(sys, "argv", ["relayos-approvals", *args])
        approvals.main()
        return json.loads(capsys.readouterr().out)

    jobs = call("list-command-jobs")
    assert jobs[0]["id"] == job_id
    assert jobs[0]["executable_name"] == "python"
    assert call("cancel-command-job", job_id)["cancellation_requested"]
    assert state.command_job(job_id)["cancel_requested"] == 1


def test_authenticated_local_output_route_rejects_anonymous(tmp_path, monkeypatch):
    import asyncio
    import json
    from starlette.requests import Request
    from laptop_bridge import control

    sid, project = session(tmp_path)
    job_id = state.create_command_job(sid, str(project), str(project), "python")
    token = "test-control-token-value"
    monkeypatch.setattr(control, "control_token", lambda: token)

    def request(header=None):
        headers = [] if header is None else [(b"x-relayos-control-token", header.encode())]
        return Request({
            "type": "http",
            "method": "GET",
            "path": "/control/command-job-output/" + job_id,
            "query_string": b"stdout_offset=0&stderr_offset=0",
            "headers": headers,
            "scheme": "http",
            "server": ("127.0.0.1", 8765),
        })

    denied = asyncio.run(control.handle(request()))
    assert denied.status_code == 401
    accepted = asyncio.run(control.handle(request(token)))
    assert accepted.status_code == 200
    payload = json.loads(accepted.body)
    assert payload["id"] == job_id
    assert payload["output_unavailable"] is True
    assert "argv" not in payload


def test_local_job_list_and_cancel_routes_require_control_token(tmp_path, monkeypatch):
    import asyncio
    import json
    from starlette.requests import Request
    from laptop_bridge import control

    sid, project = session(tmp_path)
    job_id = state.create_command_job(sid, str(project), str(project), "example")
    token = "test-isolated-control-token"
    monkeypatch.setattr(control, "control_token", lambda: token)

    def request(method, path, *, provided=None, query=b"", body=b"{}"):
        headers = [] if provided is None else [
            (b"x-relayos-control-token", provided.encode())
        ]
        async def receive():
            return {"type": "http.request", "body": body, "more_body": False}
        return Request({
            "type": "http", "method": method, "path": path,
            "query_string": query, "headers": headers,
            "scheme": "http", "server": ("127.0.0.1", 8765),
        }, receive=receive)

    path = "/control/command-jobs"
    assert asyncio.run(control.handle(request("GET", path))).status_code == 401
    assert asyncio.run(control.handle(request("GET", path, provided="wrong"))).status_code == 401
    jobs = asyncio.run(control.handle(request("GET", path, provided=token)))
    assert jobs.status_code == 200
    payload = json.loads(jobs.body)
    assert payload["jobs"][0]["id"] == job_id
    assert "argv" not in payload["jobs"][0]
    assert asyncio.run(control.handle(request("GET", path, provided=token, query=b"limit=-1"))).status_code == 400
    assert asyncio.run(control.handle(request("GET", path, provided=token, query=b"limit=nan"))).status_code == 400

    cancellation = "/control/command-jobs/cancel"
    body = json.dumps({"job_id": job_id}).encode()
    assert asyncio.run(control.handle(request("POST", cancellation, body=body))).status_code == 401
    assert state.command_job(job_id)["cancel_requested"] == 0
    assert asyncio.run(control.handle(request("POST", cancellation, provided=token, body=b'{"job_id":"missing"}'))).status_code == 404
    accepted = asyncio.run(control.handle(request("POST", cancellation, provided=token, body=body)))
    assert accepted.status_code == 200
    assert json.loads(accepted.body)["cancellation_requested"] is True
    assert state.command_job(job_id)["cancel_requested"] == 1


def test_output_keeps_incomplete_utf8_bytes_until_next_poll():
    # Files may be observed halfway through a multibyte write. Offsets must
    # point to the last complete Unicode scalar rather than corrupting text.
    runtime = command_jobs._Runtime()
    manager = command_jobs.manager
    manager._jobs["unicode-test"] = runtime
    try:
        encoded = "✓".encode("utf-8")
        runtime.stdout.write(encoded[:2])
        runtime.stdout.flush()
        first = manager.output("unicode-test")
        assert first["stdout"] == ""
        assert first["stdout_offset"] == 0
        runtime.stdout.write(encoded[2:])
        runtime.stdout.flush()
        second = manager.output("unicode-test", stdout_offset=first["stdout_offset"])
        assert second["stdout"] == "✓"
        assert second["stdout_offset"] == 3
        runtime.stdout.write(b"\xff")
        runtime.stdout.flush()
        runtime.finished_at = time.time()
        final = manager.output("unicode-test", stdout_offset=3)
        assert final["stdout"] == "\ufffd"
        assert final["stdout_offset"] == 4
    finally:
        manager._jobs.pop("unicode-test", None)
        runtime.close()
