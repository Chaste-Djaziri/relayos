import subprocess
import threading
import time
from pathlib import Path

import pytest

from laptop_bridge import server, state


@pytest.fixture(autouse=True)
def isolated_state(tmp_path, monkeypatch):
    state_dir = tmp_path / "state"
    state_dir.mkdir()
    monkeypatch.setattr(state, "STATE_DIR", state_dir)
    monkeypatch.setattr(state, "DATABASE_FILE", state_dir / "state.sqlite3")


@pytest.fixture
def project_dir(tmp_path):
    proj = tmp_path / "my_project"
    proj.mkdir()
    (proj / "main.py").write_text("print('hello world')\n", encoding="utf-8")
    (proj / "sub").mkdir()
    (proj / "sub" / "module.py").write_text("x = 42\n", encoding="utf-8")
    return proj


def test_project_session_approval_and_activation(project_dir):
    res = server.propose_project_session(str(project_dir))
    req_id = res["request_id"]
    assert "Approve this selected project locally" in res["message"]

    # Before approval, status activation fails
    with pytest.raises(PermissionError):
        server.project_session_status(req_id)

    # Human approves locally
    state.approve(req_id)

    # Now activation succeeds and returns 60-minute session
    activated = server.project_session_status(req_id)
    session_id = activated["session_id"]
    assert activated["root"] == str(project_dir.resolve())
    assert activated["expires_at"] > time.time() + 3500

    # Verification through state
    sess = state.project_session(session_id)
    assert sess["root"] == str(project_dir.resolve())


def test_project_session_expiry_at_60_minutes(project_dir, monkeypatch):
    res = server.propose_project_session(str(project_dir))
    state.approve(res["request_id"])
    activated = server.project_session_status(res["request_id"])
    session_id = activated["session_id"]

    # Within 60 minutes it is active
    assert state.project_session(session_id)["session_id"] == session_id

    # Fast forward past 60 minutes (3601 seconds)
    current_time = time.time()
    monkeypatch.setattr(state.time, "time", lambda: current_time + 3605)

    with pytest.raises(PermissionError, match="Missing, expired, or revoked"):
        state.project_session(session_id)


def test_project_session_emergency_stop_revocation(project_dir):
    res = server.propose_project_session(str(project_dir))
    state.approve(res["request_id"])
    activated = server.project_session_status(res["request_id"])
    session_id = activated["session_id"]

    # Trigger emergency stop
    state.set_emergency_stop(True)
    with pytest.raises(PermissionError, match="Emergency stop"):
        server.read_project_file(session_id, "main.py")

    # Future proposal rejected
    with pytest.raises(PermissionError, match="Emergency stop"):
        server.propose_project_session(str(project_dir))

    # Even after emergency stop is disabled, revoked sessions remain revoked
    state.set_emergency_stop(False)
    with pytest.raises(PermissionError, match="Missing, expired, or revoked"):
        server.read_project_file(session_id, "main.py")


def test_root_containment_and_symlink_escape(project_dir, tmp_path):
    res = server.propose_project_session(str(project_dir))
    state.approve(res["request_id"])
    session_id = server.project_session_status(res["request_id"])["session_id"]

    # 1. Path traversal with .. outside project root
    with pytest.raises(PermissionError, match="outside the approved project root"):
        server.read_project_file(session_id, "../outside.txt")

    # 2. Symlink pointing outside project root
    outside_file = tmp_path / "secret.txt"
    outside_file.write_text("classified")
    symlink_file = project_dir / "link_to_secret.txt"
    symlink_file.symlink_to(outside_file)

    with pytest.raises(PermissionError, match="outside the approved project root"):
        server.read_project_file(session_id, "link_to_secret.txt")

    # 3. Attempting to write escaping root
    with pytest.raises(PermissionError, match="outside the approved project root"):
        server.write_project_file(session_id, "../evil.txt", "attack")

    # 4. Attempting command cwd outside root
    with pytest.raises(PermissionError, match="outside the approved project root"):
        server.run_project_command(session_id, ["echo", "hi"], cwd="../")


def test_file_read_write_and_size_caps(project_dir):
    res = server.propose_project_session(str(project_dir))
    state.approve(res["request_id"])
    session_id = server.project_session_status(res["request_id"])["session_id"]

    # Read existing file
    content = server.read_project_file(session_id, "main.py")
    assert content == "print('hello world')\n"

    # Write new file
    write_res = server.write_project_file(session_id, "sub/new_file.txt", "sample data")
    assert write_res["bytes_written"] == 11
    assert server.read_project_file(session_id, "sub/new_file.txt") == "sample data"

    # List files
    files = server.list_project_files(session_id, ".")
    names = {f["name"] for f in files}
    assert "main.py" in names
    assert "sub" in names

    # Size cap test (> 1 MiB)
    large_content = "A" * 1_000_001
    with pytest.raises(ValueError, match="exceeds the 1 MiB"):
        server.write_project_file(session_id, "large.txt", large_content)


def test_apply_project_patch(project_dir):
    # Initialize a git repo in project_dir
    subprocess.run(["git", "init"], cwd=project_dir, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.name", "Tester"], cwd=project_dir, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=project_dir, check=True, capture_output=True)
    subprocess.run(["git", "add", "main.py"], cwd=project_dir, check=True, capture_output=True)
    subprocess.run(["git", "commit", "-m", "init"], cwd=project_dir, check=True, capture_output=True)

    res = server.propose_project_session(str(project_dir))
    state.approve(res["request_id"])
    session_id = server.project_session_status(res["request_id"])["session_id"]

    patch = """diff --git a/main.py b/main.py
--- a/main.py
+++ b/main.py
@@ -1 +1 @@
-print('hello world')
+print('patched by laptop bridge')
"""
    patch_res = server.apply_project_patch(session_id, patch)
    assert patch_res["applied"] is True
    assert server.read_project_file(session_id, "main.py") == "print('patched by laptop bridge')\n"


def test_run_project_command_security_and_caps(project_dir):
    res = server.propose_project_session(str(project_dir))
    state.approve(res["request_id"])
    session_id = server.project_session_status(res["request_id"])["session_id"]

    # Rejection of privilege escalation
    for evil in [["sudo", "ls"], ["su", "root"], ["doas", "cat"]]:
        with pytest.raises(PermissionError, match="Privilege escalation"):
            server.run_project_command(session_id, evil)

    # Valid command execution
    cmd_res = server.run_project_command(session_id, ["echo", "test-bridge"])
    assert cmd_res["exit_code"] == 0
    assert "test-bridge" in cmd_res["stdout"]

    # Output capping at 8192 chars
    long_output_cmd = ["python3", "-c", "print('x' * 10000)"]
    cap_res = server.run_project_command(session_id, long_output_cmd)
    assert len(cap_res["stdout"]) <= 8192


def test_concurrent_project_operations(project_dir):
    res = server.propose_project_session(str(project_dir))
    state.approve(res["request_id"])
    session_id = server.project_session_status(res["request_id"])["session_id"]

    errors = []

    def writer(i):
        try:
            server.write_project_file(session_id, f"worker_{i}.txt", f"data {i}")
            data = server.read_project_file(session_id, f"worker_{i}.txt")
            if data != f"data {i}":
                errors.append(f"Mismatch in worker {i}")
        except Exception as e:
            errors.append(str(e))

    threads = [threading.Thread(target=writer, args=(i,)) for i in range(5)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert errors == []
    files = server.list_project_files(session_id, ".")
    assert len(files) >= 6
