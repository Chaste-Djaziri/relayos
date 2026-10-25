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
    assert "Confirm this folder-access request in ChatGPT" in res["message"]

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


def test_approve_project_session_is_idempotent_after_reconnect(project_dir):
    proposal = server.propose_project_session(str(project_dir))

    first = server.approve_project_session(proposal["request_id"])
    second = server.approve_project_session(proposal["request_id"])

    assert second["session_id"] == first["session_id"]
    assert second["root"] == str(project_dir.resolve())


def test_project_session_creates_an_approved_new_root(tmp_path):
    project_dir = tmp_path / "Documents" / "new-coding-project"

    proposal = server.propose_project_session(str(project_dir))

    assert proposal["project_root"] == str(project_dir)
    assert proposal["will_create_project_root"] is True
    assert not project_dir.exists()

    state.approve(proposal["request_id"])
    session = server.project_session_status(proposal["request_id"])

    assert project_dir.is_dir()
    assert session["root"] == str(project_dir.resolve())
    assert server.write_project_file(session["session_id"], "src/main.py", "print('ready')\n")["bytes_written"] == 15


def test_project_session_relative_path_is_anchored_at_home(tmp_path, monkeypatch):
    monkeypatch.setattr(server.Path, "home", classmethod(lambda cls: tmp_path))

    proposal = server.propose_project_session("Documents/github/new-project")

    assert proposal["project_root"] == str(tmp_path / "Documents" / "github" / "new-project")


def test_persistent_folder_permission_reuses_session_without_a_new_request(project_dir):
    state.grant_folder(str(project_dir))

    proposal = server.propose_project_session(str(project_dir))

    assert proposal["reused_persistent_permission"] is True
    assert state.project_session(proposal["session_id"])["root"] == str(project_dir.resolve())
    assert state.pending_requests() == []


def test_grant_folder_replaces_an_existing_active_grant(project_dir):
    first = state.grant_folder(str(project_dir))
    second = state.grant_folder(str(project_dir))

    active = state.active_permission_grants()
    assert [grant["token"] for grant in active] == [second]
    assert first != second


def test_folder_grants_are_case_insensitive_for_existing_path_components(tmp_path):
    project_dir = tmp_path / "GitHub" / "Bika"
    project_dir.mkdir(parents=True)

    state.grant_folder(str(tmp_path / "github" / "bika"))

    assert state.folder_granted(project_dir)
    active = state.active_permission_grants()
    assert active[0]["scope"] == str(project_dir)


def test_existing_folder_grants_are_migrated_to_canonical_path(tmp_path):
    project_dir = tmp_path / "GitHub" / "Bika"
    project_dir.mkdir(parents=True)
    legacy_scope = str(tmp_path / "github" / "bika")

    # Simulate a grant written by RelayOS before path normalization existed.
    with state._db() as connection:
        connection.execute(
            "INSERT INTO permission_grants VALUES (?, 'folder', 'persistent', ?, ?, ?, NULL, NULL)",
            ("legacy-grant", legacy_scope, '{\"folder\": \"legacy\"}', time.time()),
        )
    state._INITIALIZED_DBS.discard(str(state.DATABASE_FILE))

    assert state.folder_granted(project_dir)
    active = state.active_permission_grants()
    assert active[0]["scope"] == str(project_dir)


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

    # Commands require an exact one-use ChatGPT approval before execution.
    argv = ["echo", "test-bridge"]
    unapproved = server.run_project_command(session_id, argv)
    assert unapproved["executed"] is False
    assert unapproved["requires_authorization"] is True
    permission = server.authorize_project_command(session_id, argv)
    cmd_res = server.run_project_command(session_id, argv, authorization_token=permission["authorization_token"])
    assert cmd_res["exit_code"] == 0
    assert "test-bridge" in cmd_res["stdout"]

    # Output capping at 8192 chars
    long_output_cmd = ["python3", "-c", "print('x' * 10000)"]
    permission = server.authorize_project_command(session_id, long_output_cmd)
    cap_res = server.run_project_command(session_id, long_output_cmd, authorization_token=permission["authorization_token"])
    assert len(cap_res["stdout"]) <= 8192


def test_coding_command_path_supports_launchd_tool_locations(monkeypatch):
    monkeypatch.setenv("PATH", "/usr/bin:/bin")

    path = server._coding_command_path().split(":")

    assert "/usr/bin" in path
    assert "/opt/homebrew/bin" in path
    assert "/usr/local/bin" in path


def test_one_use_command_grant_is_exact_and_single_use(project_dir):
    res = server.propose_project_session(str(project_dir))
    state.approve(res["request_id"])
    session_id = server.project_session_status(res["request_id"])["session_id"]
    argv = ["echo", "approved"]
    authorization = server.authorize_project_command(session_id, argv)
    token = authorization["authorization_token"]

    mismatched = server.run_project_command(session_id, ["echo", "different"], authorization_token=token)
    assert mismatched["requires_authorization"] is True
    assert server.run_project_command(session_id, argv, authorization_token=token)["exit_code"] == 0
    used = server.run_project_command(session_id, argv, authorization_token=token)
    assert used["requires_authorization"] is True


def test_project_relative_executable_is_resolved_from_command_cwd(project_dir):
    executable = project_dir / "node_modules" / ".bin" / "tool"
    executable.parent.mkdir(parents=True)
    executable.write_text("#!/bin/sh\necho local-tool\n", encoding="utf-8")
    executable.chmod(0o755)

    assert server._resolve_executable("./node_modules/.bin/tool", project_dir) == str(executable.resolve())


def test_persistent_command_grant_allows_arguments_in_project_and_can_be_revoked(project_dir):
    res = server.propose_project_session(str(project_dir))
    state.approve(res["request_id"])
    session_id = server.project_session_status(res["request_id"])["session_id"]

    grant = server.authorize_project_command(session_id, ["echo", "first"], grant="always")
    assert grant["authorization_token"] is None
    assert server.run_project_command(session_id, ["echo", "build"])["exit_code"] == 0
    assert server.run_project_command(session_id, ["echo", "another argument"])["exit_code"] == 0
    saved = server.list_saved_command_grants()
    assert len(saved) == 1
    assert saved[0]["project_root"] == str(project_dir.resolve())

    server.revoke_saved_command_grant(saved[0]["token"])
    assert server.run_project_command(session_id, ["echo", "after revoke"])["requires_authorization"] is True


def test_saved_command_grant_is_project_scoped_and_emergency_stop_blocks_it(project_dir, tmp_path):
    other_root = tmp_path / "other_project"
    other_root.mkdir()
    first = server.propose_project_session(str(project_dir))
    state.approve(first["request_id"])
    first_session = server.project_session_status(first["request_id"])["session_id"]
    server.authorize_project_command(first_session, ["echo", "allowed"], grant="always")

    second = server.propose_project_session(str(other_root))
    state.approve(second["request_id"])
    second_session = server.project_session_status(second["request_id"])["session_id"]
    assert server.run_project_command(second_session, ["echo", "not allowed"])["requires_authorization"] is True

    state.set_emergency_stop(True)
    with pytest.raises(PermissionError, match="Emergency stop"):
        server.run_project_command(first_session, ["echo", "blocked"])


def test_permission_expansion_tools_have_destructive_annotations():
    tools = {tool.name: tool for tool in server.mcp._tool_manager.list_tools()}
    for name in ("propose_project_session", "approve_project_session", "authorize_project_command", "write_project_file", "apply_project_patch"):
        assert tools[name].annotations is not None
        assert tools[name].annotations.destructive_hint is True
    assert tools["run_project_command"].annotations.destructive_hint is True


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
