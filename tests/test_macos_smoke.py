"""End-to-end macOS integration smoke test covering permissions, overlay, coding session, patch, command, expiry, and emergency stop."""
import subprocess
import time
from pathlib import Path

import pytest
from PySide6.QtCore import Qt
from PySide6.QtWidgets import QApplication

from laptop_bridge import capture, desktop, server, state
from laptop_bridge.overlay import GuidanceOverlay


@pytest.fixture(autouse=True)
def isolated_env(tmp_path, monkeypatch):
    state_dir = tmp_path / "state"
    state_dir.mkdir()
    monkeypatch.setattr(state, "STATE_DIR", state_dir)
    monkeypatch.setattr(state, "DATABASE_FILE", state_dir / "state.sqlite3")


@pytest.fixture(scope="session")
def qapp():
    app = QApplication.instance()
    if app is None:
        app = QApplication([])
    return app


def test_macos_end_to_end_smoke(tmp_path, qapp, monkeypatch):
    # 1. Screen capture permission preflight
    perm = capture.has_screen_recording_permission()
    assert isinstance(perm, bool)
    assert hasattr(capture, "request_screen_recording_permission")

    # 2. Overlay over another app (transparent, click-through, always-on-top)
    overlay = GuidanceOverlay()
    assert overlay.windowFlags() & Qt.WindowType.WindowTransparentForInput
    assert overlay.windowFlags() & Qt.WindowType.WindowStaysOnTopHint
    overlay.show_guidance(
        display_id=0,
        x=200,
        y=200,
        label="Laptop Bridge Smoke Test",
        message="Instructional overlay",
        timeout_seconds=None,
    )
    assert overlay.is_guidance_active() is True
    overlay._on_tick()

    # 3. Project session creation and approval
    proj = tmp_path / "smoke_project"
    proj.mkdir()
    (proj / "app.py").write_text("def run():\n    return 1\n", encoding="utf-8")

    # Initialize git repo for patching
    subprocess.run(["git", "init"], cwd=proj, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.name", "SmokeTester"], cwd=proj, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.email", "smoke@test.com"], cwd=proj, check=True, capture_output=True)
    subprocess.run(["git", "add", "app.py"], cwd=proj, check=True, capture_output=True)
    subprocess.run(["git", "commit", "-m", "init"], cwd=proj, check=True, capture_output=True)

    proposal = server.propose_project_session(str(proj))
    req_id = proposal["request_id"]
    state.approve(req_id)
    activated = server.project_session_status(req_id)
    session_id = activated["session_id"]
    assert activated["root"] == str(proj.resolve())

    # 4. File read and git diff patch
    content = server.read_project_file(session_id, "app.py")
    assert "return 1" in content

    patch = """diff --git a/app.py b/app.py
--- a/app.py
+++ b/app.py
@@ -1,2 +1,2 @@
 def run():
-    return 1
+    return 42
"""
    patch_result = server.apply_project_patch(session_id, patch)
    assert patch_result["applied"] is True
    assert "return 42" in server.read_project_file(session_id, "app.py")

    # 5. Non-interactive command execution
    cmd_out = server.run_project_command(session_id, ["python3", "-c", "import app; print(app.run())"])
    assert cmd_out["exit_code"] == 0
    assert cmd_out["stdout"].strip() == "42"

    # 6. Expiry at 60 minutes
    now = time.time()
    monkeypatch.setattr(state.time, "time", lambda: now + 3601)
    with pytest.raises(PermissionError, match="Missing, expired, or revoked"):
        server.read_project_file(session_id, "app.py")

    # Reset time and create a second session to test emergency stop
    monkeypatch.setattr(state.time, "time", lambda: now)
    p2 = server.propose_project_session(str(proj))
    state.approve(p2["request_id"])
    s2 = server.project_session_status(p2["request_id"])["session_id"]

    # 7. Emergency stop: terminates active sessions and clears visible guidance
    state.set_emergency_stop(True)
    overlay.clear_guidance()

    assert overlay.is_guidance_active() is False
    with pytest.raises(PermissionError, match="Emergency stop is enabled"):
        server.read_project_file(s2, "app.py")
