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

    # Reject without independent local approval
    with pytest.raises(PermissionError, match="Project session has not been approved locally"):
        server.approve_project_session(proposal["request_id"])

    # Local user approves on the laptop
    state.approve(proposal["request_id"])

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

    # Commands require independent local approval before execution.
    argv = ["echo", "test-bridge"]
    unapproved = server.run_project_command(session_id, argv)
    assert unapproved["executed"] is False
    assert unapproved["requires_authorization"] is True
    req = server.authorize_project_command(session_id, argv)
    assert req["requires_local_approval"] is True
    assert req["authorization_token"] is None
    state.approve(req["request_id"])
    permission = server.authorize_project_command(session_id, argv)
    cmd_res = server.run_project_command(session_id, argv, authorization_token=permission["authorization_token"])
    assert cmd_res["exit_code"] == 0
    assert "test-bridge" in cmd_res["stdout"]

    # Output capping at 8192 chars
    long_output_cmd = ["python3", "-c", "print('x' * 10000)"]
    req = server.authorize_project_command(session_id, long_output_cmd)
    state.approve(req["request_id"])
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
    req = server.authorize_project_command(session_id, argv)
    state.approve(req["request_id"])
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


def test_reusable_command_is_exact_and_can_be_revoked(project_dir):
    res = server.propose_project_session(str(project_dir))
    state.approve(res["request_id"])
    session_id = server.project_session_status(res["request_id"])["session_id"]
    argv = ["echo", "first"]
    pending = server.authorize_project_command(session_id, argv, grant="always")
    assert pending["requires_local_approval"] is True
    state.decide_request(pending["request_id"], "persistent")
    granted = server.authorize_project_command(session_id, argv, grant="always")
    assert granted["grant"] == "always"
    assert server.run_project_command(session_id, argv)["exit_code"] == 0
    assert server.run_project_command(session_id, ["echo", "other"])["requires_authorization"]
    saved = server.list_saved_command_grants()
    assert len(saved) == 1
    server.revoke_saved_command_grant(saved[0]["token"])
    assert server.run_project_command(session_id, argv)["requires_authorization"]


def _approved_project_session(project_dir):
    proposal = server.propose_project_session(str(project_dir))
    state.approve(proposal["request_id"])
    return server.project_session_status(proposal["request_id"])["session_id"]


def test_automatic_git_commit_prefix_is_reused_without_client_scope(project_dir):
    sid = _approved_project_session(project_dir)
    command = ["git", "commit", "-m", "first"]
    pending = server.authorize_project_command(sid, command)
    assert pending["scope_prefix"] == ["git", "commit"]
    assert state.pending_requests()[0]["context"]["scope_prefix"] == ["git", "commit"]
    state.decide_request(pending["request_id"], "persistent")
    approved = server.authorize_project_command(sid, command)
    assert approved["grant"] == "always"
    assert approved["scope_prefix"] == ["git", "commit"]
    different = ["git", "commit", "-m", "different message"]
    assert server.authorize_project_command(sid, different)["reused_saved_grant"]
    assert state.has_saved_command_grant(
        str(project_dir), server._resolve_executable("git"), different, str(project_dir), sid)
    assert server.run_project_command(sid, ["git", "push", "origin", "main"])["requires_authorization"]


def test_automatic_scope_suggestions_are_narrow(project_dir):
    from laptop_bridge.command_policy import suggested_scope_prefix
    cases = [
        ("/opt/homebrew/bin/npm", ["npm", "install", "one"], ["npm", "install"]),
        ("/opt/homebrew/bin/npm", ["npm", "run", "build", "--watch"], ["npm", "run", "build"]),
        ("/usr/bin/git", ["git", "log", "-3"], ["git", "log"]),
        ("/usr/bin/xcrun", ["xcrun", "swift", "test", "--package-path", "."], ["xcrun", "swift", "test"]),
        ("/bin/bash", ["bash", "-c", "echo"], None),
        ("/usr/bin/git", ["git", "-c", "foo", "commit"], None),
        ("/usr/bin/env", ["env", "sh", "script"], None),
        ("/usr/bin/git", ["git", "add", "--", "file"], None),
    ]
    for executable, argv, expected in cases:
        assert suggested_scope_prefix(executable, argv) == expected


def test_explicit_commit_prefix_reuses_different_messages_without_approving_other_git_actions(project_dir):
    sid = _approved_project_session(project_dir)
    first = ["git", "commit", "-m", "initial"]
    prefix = ["git", "commit"]
    pending = server.authorize_project_command(sid, first, scope_prefix=prefix)
    assert pending["scope_prefix"] == prefix
    assert state.pending_requests()[0]["context"]["scope_prefix"] == prefix
    state.decide_request(pending["request_id"], "persistent")
    approved = server.authorize_project_command(sid, first, scope_prefix=prefix)
    assert approved["grant"] == "always"
    assert approved["scope_prefix"] == prefix
    different = ["git", "commit", "-m", "next message"]
    assert server.authorize_project_command(sid, different)["reused_saved_grant"]
    assert state.has_saved_command_grant(str(project_dir), server._resolve_executable("git"),
                                         different, str(project_dir), sid)
    assert server.run_project_command(sid, ["git", "reset", "--hard"])["requires_authorization"]
    assert server.run_project_command(sid, ["git", "push", "origin", "main"])["requires_authorization"]


def test_dynamic_command_prefix_for_other_tools_and_session_boundary(project_dir):
    sid = _approved_project_session(project_dir)
    first = ["echo", "approved", "one"]
    prefix = ["echo", "approved"]
    pending = server.authorize_project_command(sid, first, scope_prefix=prefix, grant="once")
    state.decide_request(pending["request_id"], "session")
    approved = server.authorize_project_command(sid, first, scope_prefix=prefix, grant="once")
    assert approved["grant"] == "session"
    assert server.run_project_command(sid, ["echo", "approved", "two"])["exit_code"] == 0
    assert server.run_project_command(sid, ["echo", "not-approved", "two"])["requires_authorization"]
    other = _approved_project_session(project_dir)
    assert server.run_project_command(other, ["echo", "approved", "three"])["requires_authorization"]


def test_changing_requested_prefix_cannot_repurpose_local_approval(project_dir):
    sid = _approved_project_session(project_dir)
    command = ["git", "commit", "-m", "one"]
    request = server.authorize_project_command(sid, command, scope_prefix=["git", "commit"])
    state.decide_request(request["request_id"], "persistent")
    attempted = server.authorize_project_command(
        sid, command, scope_prefix=["git", "commit", "-m"], request_id=request["request_id"]
    )
    assert attempted["requires_local_approval"]
    assert attempted["request_id"] != request["request_id"]


def test_dynamic_prefix_survives_fresh_helper_and_can_be_revoked(project_dir):
    sid = _approved_project_session(project_dir)
    argv = ["echo", "dynamic", "original"]
    prefix = ["echo", "dynamic"]
    req = server.authorize_project_command(sid, argv, scope_prefix=prefix)
    state.decide_request(req["request_id"], "persistent")
    server.authorize_project_command(sid, argv, scope_prefix=prefix)
    saved = server.list_saved_command_grants()
    assert len(saved) == 1
    assert saved[0]["scope_prefix"] == prefix

    # Every standalone approval-helper process re-opens the SQLite database.
    # It must preserve explicitly approved prefixes while revoking legacy
    # executable-only wildcard grants.
    state._INITIALIZED_DBS.discard(str(state.DATABASE_FILE))
    state.pending_requests()
    assert server.run_project_command(sid, ["echo", "dynamic", "changed"])["exit_code"] == 0

    server.revoke_saved_command_grant(saved[0]["token"])
    assert server.run_project_command(sid, ["echo", "dynamic", "changed"])["requires_authorization"]


def test_invalid_persisted_prefix_cannot_authorize_arbitrary_commands(project_dir):
    sid = _approved_project_session(project_dir)
    import json
    executable = server._resolve_executable("echo")
    with state._db() as db:
        db.execute(
            """INSERT INTO command_grants
               (token, project_root, executable, argv_digest, working_directory,
                grant_type, created_at, prefix_json)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            ("invalid-prefix", str(project_dir), executable, None, str(project_dir),
             "always", time.time(), "null"),
        )
    assert server.run_project_command(sid, ["echo", "anything"])["requires_authorization"]


def test_npm_dynamic_prefix_state_matching_without_running_install(project_dir):
    from laptop_bridge.command_policy import validate_scope_prefix
    argv = ["npm", "install", "some-package"]
    prefix = validate_scope_prefix("/opt/homebrew/bin/npm", argv, ["npm", "install"])
    state.grant_project_command(
        str(project_dir), "/opt/homebrew/bin/npm", argv, str(project_dir),
        grant_type="always", scope_prefix=prefix
    )
    assert state.has_saved_command_grant(str(project_dir), "/opt/homebrew/bin/npm",
                                         ["npm", "install", "another-package"], str(project_dir))
    assert not state.has_saved_command_grant(str(project_dir), "/opt/homebrew/bin/npm",
                                             ["npm", "run", "build"], str(project_dir))


def test_literal_prefix_validation_and_exact_only_interpreters(project_dir):
    sid = _approved_project_session(project_dir)
    cases = [
        (["git", "commit", "-m", "one"], ["git"]),
        (["git", "commit", "-m", "one"], ["git", "push"]),
        (["git", "-c", "core.hooksPath=.", "commit"], ["git", "-c"]),
        (["bash", "-c", "echo harmless"], ["bash", "-c"]),
        (["python3", "-c", "print(1)"], ["python3", "-c"]),
        (["env", "GIT_CONFIG=..."], ["env", "GIT_CONFIG=..."]),
    ]
    for command, prefix in cases:
        with pytest.raises(ValueError):
            server.authorize_project_command(sid, command, scope_prefix=prefix)
    from laptop_bridge.command_policy import validate_scope_prefix
    assert validate_scope_prefix("/opt/homebrew/bin/npm", ["npm", "run", "build", "--", "--watch"], ["npm", "run", "build"]) == ["npm", "run", "build"]
    assert validate_scope_prefix("/opt/homebrew/bin/npm", ["npm", "install", "left-pad"], ["npm", "install"]) == ["npm", "install"]


def test_one_time_prefix_approval_does_not_remember_other_arguments(project_dir):
    sid = _approved_project_session(project_dir)
    command = ["echo", "scope", "first"]
    request = server.authorize_project_command(sid, command, scope_prefix=["echo", "scope"])
    state.decide_request(request["request_id"], "once")
    result = server.authorize_project_command(sid, command, scope_prefix=["echo", "scope"])
    assert result["grant"] == "once" and result["authorization_token"]
    assert server.run_project_command(sid, ["echo", "scope", "other"])["requires_authorization"]
    assert server.run_project_command(sid, command, authorization_token=result["authorization_token"])["exit_code"] == 0


def test_git_add_persistent_family_after_local_always_choice(project_dir):
    subprocess.run(["git", "init"], cwd=project_dir, check=True, capture_output=True)
    sid = _approved_project_session(project_dir)
    first = ["git", "add", "--", "main.py"]
    pending = server.authorize_project_command(sid, first)  # Client defaults to once.
    assert pending["command_family"] == "git add"
    assert state.pending_requests()[0]["context"]["command_family"] == "git:add"
    state.decide_request(pending["request_id"], "persistent")  # User chooses Always.
    granted = server.authorize_project_command(sid, first)
    assert granted["grant"] == "always"
    assert granted["authorization_token"] is None
    assert granted["command_family"] == "git add"

    assert server.run_project_command(sid, first)["exit_code"] == 0
    next_command = ["git", "add", "--", "sub/module.py"]
    assert server.authorize_project_command(sid, next_command)["reused_saved_grant"]
    assert server.run_project_command(sid, next_command)["exit_code"] == 0
    staged = subprocess.check_output(["git", "diff", "--cached", "--name-only"], cwd=project_dir, text=True)
    assert "main.py" in staged and "sub/module.py" in staged
    assert server.run_project_command(sid, ["git", "reset", "--hard"])["requires_authorization"]
    assert server.run_project_command(sid, ["git", "commit", "-m", "unapproved"])["requires_authorization"]
    assert server.run_project_command(sid, ["git", "-C", str(project_dir), "add", "main.py"])["requires_authorization"]


def test_git_add_grant_survives_fresh_approval_helper_database_open(project_dir):
    subprocess.run(["git", "init"], cwd=project_dir, check=True, capture_output=True)
    sid = _approved_project_session(project_dir)
    original = ["git", "add", "-n", "--", "main.py"]
    pending = server.authorize_project_command(sid, original)
    state.decide_request(pending["request_id"], "persistent")
    assert server.authorize_project_command(sid, original)["grant"] == "always"

    with state._db() as db:
        db.execute(
            """INSERT INTO command_grants
               (token, project_root, executable, grant_type, created_at)
               VALUES (?, ?, ?, ?, ?)""",
            ("obsolete-wildcard", str(project_dir), server._resolve_executable("git"),
             "always", time.time()),
        )

    # Mimic a fresh standalone RelayOSApprovals process, which re-runs the
    # database migration on its first access.
    state._INITIALIZED_DBS.discard(str(state.DATABASE_FILE))
    state.pending_requests()

    with state._db() as db:
        legacy = db.execute(
            "SELECT revoked_at FROM command_grants WHERE token = 'obsolete-wildcard'"
        ).fetchone()
    assert legacy["revoked_at"] is not None
    assert any(grant["family_key"] == "git:add" for grant in server.list_saved_command_grants())
    assert server.run_project_command(sid, ["git", "add", "-n", "--", "sub/module.py"])["exit_code"] == 0


def test_git_add_session_family_is_bound_to_approved_session(project_dir):
    subprocess.run(["git", "init"], cwd=project_dir, check=True, capture_output=True)
    sid = _approved_project_session(project_dir)
    request = server.authorize_project_command(sid, ["git", "add", "--", "main.py"])
    state.decide_request(request["request_id"], "session")
    assert server.authorize_project_command(sid, ["git", "add", "--", "main.py"])["grant"] == "session"
    assert server.run_project_command(sid, ["git", "add", "--", "sub/module.py"])["exit_code"] == 0

    another_session = _approved_project_session(project_dir)
    assert another_session != sid
    assert server.run_project_command(another_session, ["git", "add", "--", "main.py"])["requires_authorization"]


def test_git_add_once_remains_exact_even_when_family_available(project_dir):
    subprocess.run(["git", "init"], cwd=project_dir, check=True, capture_output=True)
    sid = _approved_project_session(project_dir)
    first = ["git", "add", "--", "main.py"]
    request = server.authorize_project_command(sid, first, grant="always")
    state.decide_request(request["request_id"], "once")
    authorization = server.authorize_project_command(sid, first, grant="always")
    assert authorization["grant"] == "once"
    assert authorization["command_family"] is None
    assert server.run_project_command(sid, ["git", "add", "--", "sub/module.py"])["requires_authorization"]
    assert server.run_project_command(sid, first, authorization_token=authorization["authorization_token"])["exit_code"] == 0
    assert server.run_project_command(sid, first, authorization_token=authorization["authorization_token"])["requires_authorization"]


def test_git_family_approval_requires_same_working_directory_and_executable(project_dir):
    subprocess.run(["git", "init"], cwd=project_dir, check=True, capture_output=True)
    sid = _approved_project_session(project_dir)
    first = ["git", "add", "--", "main.py"]
    request = server.authorize_project_command(sid, first)
    state.decide_request(request["request_id"], "persistent")
    server.authorize_project_command(sid, first)

    assert server.run_project_command(sid, ["git", "add", "--", "module.py"], cwd="sub")["requires_authorization"]
    assert server.run_project_command(sid, ["echo", "add", "main.py"])["requires_authorization"]
    saved = server.list_saved_command_grants()
    assert len(saved) == 1 and saved[0]["family_key"] == "git:add"
    server.revoke_saved_command_grant(saved[0]["token"])
    assert server.run_project_command(sid, ["git", "add", "--", "sub/module.py"])["requires_authorization"]


def test_unlisted_git_commands_cannot_reuse_family_grants(project_dir):
    sid = _approved_project_session(project_dir)
    for args in (["git", "push", "origin", "main"], ["git", "commit", "--amend"], ["git", "clean", "-fd"]):
        pending = server.authorize_project_command(sid, args)
        assert pending["command_family"] is None


def test_local_once_cannot_be_escalated_to_always(project_dir):
    proposal = server.propose_project_session(str(project_dir))
    state.approve(proposal["request_id"])
    sid = server.project_session_status(proposal["request_id"])["session_id"]
    argv = ["echo", "protected"]
    pending = server.authorize_project_command(sid, argv, grant="always")
    state.decide_request(pending["request_id"], "once")
    approved = server.authorize_project_command(sid, argv, grant="always")
    assert approved["grant"] == "once"
    assert approved["authorization_token"]
    assert server.list_saved_command_grants() == []
    assert server.run_project_command(sid, argv, authorization_token=approved["authorization_token"])["exit_code"] == 0
    assert server.run_project_command(sid, argv)["requires_authorization"]


def test_command_approval_binds_cwd_and_duration(project_dir):
    (project_dir / "subfolder").mkdir()
    proposal = server.propose_project_session(str(project_dir))
    state.approve(proposal["request_id"])
    sid = server.project_session_status(proposal["request_id"])["session_id"]
    argv = ["echo", "bound"]
    pending = server.authorize_project_command(sid, argv, grant="once")
    state.decide_request(pending["request_id"], "once")
    mismatch = server.authorize_project_command(sid, argv, cwd="subfolder", grant="once", request_id=pending["request_id"])
    assert mismatch["requires_local_approval"]
    mismatch_duration = server.authorize_project_command(sid, argv, grant="always", request_id=pending["request_id"])
    assert mismatch_duration["requires_local_approval"]


def test_legacy_global_grant_is_not_honored(project_dir):
    proposal = server.propose_project_session(str(project_dir))
    state.approve(proposal["request_id"])
    sid = server.project_session_status(proposal["request_id"])["session_id"]
    with state._db() as db:
        db.execute(
            "INSERT INTO command_grants (token, project_root, executable, grant_type, created_at) VALUES (?, ?, ?, ?, ?)",
            ("legacy", "/different/root", server._resolve_executable("echo"), "persistent", time.time()),
        )
    assert server.run_project_command(sid, ["echo", "should deny"])["requires_authorization"]


def test_saved_command_grant_is_project_scoped_and_emergency_stop_blocks_it(project_dir, tmp_path):
    other = tmp_path / "other"
    other.mkdir()
    first = server.propose_project_session(str(project_dir))
    state.approve(first["request_id"])
    sid = server.project_session_status(first["request_id"])["session_id"]
    argv = ["echo", "allowed"]
    pending = server.authorize_project_command(sid, argv, grant="always")
    state.decide_request(pending["request_id"], "persistent")
    server.authorize_project_command(sid, argv, grant="always")
    second = server.propose_project_session(str(other))
    state.approve(second["request_id"])
    other_sid = server.project_session_status(second["request_id"])["session_id"]
    assert server.run_project_command(other_sid, argv)["requires_authorization"]
    state.set_emergency_stop(True)
    with pytest.raises(PermissionError, match="Emergency stop"):
        server.run_project_command(sid, argv)


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


def test_command_authorization_requires_independent_local_approval(project_dir):
    res = server.propose_project_session(str(project_dir))
    state.approve(res["request_id"])
    session_id = server.project_session_status(res["request_id"])["session_id"]
    argv = ["echo", "untrusted"]

    # Calling authorize_project_command without local approval does not grant an authorization token
    auth_req = server.authorize_project_command(session_id, argv)
    assert auth_req["requires_local_approval"] is True
    assert auth_req["authorization_token"] is None

    # Calling run_project_command without token fails
    unapproved = server.run_project_command(session_id, argv)
    assert unapproved["requires_authorization"] is True

    # Denying locally prevents command execution
    state.deny(auth_req["request_id"])
    with pytest.raises(PermissionError, match="Command authorization request was denied"):
        server.authorize_project_command(session_id, argv, request_id=auth_req["request_id"])

    # A new request approved locally succeeds
    new_req = server.authorize_project_command(session_id, argv)
    state.approve(new_req["request_id"])
    granted = server.authorize_project_command(session_id, argv)
    assert granted["authorization_token"] is not None
    executed = server.run_project_command(session_id, argv, authorization_token=granted["authorization_token"])
    assert executed["exit_code"] == 0


def test_approve_project_session_without_local_approval_fails(project_dir):
    proposal = server.propose_project_session(str(project_dir))
    with pytest.raises(PermissionError, match="Project session has not been approved locally"):
        server.approve_project_session(proposal["request_id"])

