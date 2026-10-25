import base64
import threading
import time

import pytest
from PySide6.QtCore import QPointF, Qt
from PySide6.QtGui import QGuiApplication
from PySide6.QtWidgets import QApplication

from laptop_bridge import capture, desktop, server, state
from laptop_bridge.overlay import GuidanceOverlay


@pytest.fixture(autouse=True)
def isolated_state(tmp_path, monkeypatch):
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


def test_overlay_click_through_and_flags(qapp):
    overlay = GuidanceOverlay()
    flags = overlay.windowFlags()
    assert bool(flags & Qt.WindowType.FramelessWindowHint)
    assert bool(flags & Qt.WindowType.WindowStaysOnTopHint)
    assert bool(flags & Qt.WindowType.WindowTransparentForInput)
    assert overlay.testAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
    assert overlay.testAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
    assert overlay.testAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)


def test_overlay_lifecycle_and_motion(qapp, monkeypatch):
    overlay = GuidanceOverlay()
    overlay.show_guidance(
        display_id=0,
        x=250,
        y=300,
        label="Test Guide",
        message="Follow pointer",
        timeout_seconds=None,
    )
    assert overlay.is_guidance_active() is True
    assert overlay.state == GuidanceOverlay.STATE_MOVING
    assert overlay.target_pt.x() == 250
    assert overlay.target_pt.y() == 300

    start_time = overlay.anim_start_time

    # Advance 300ms (halfway through movement)
    monkeypatch.setattr(time, "monotonic", lambda: start_time + 0.3)
    overlay._on_tick()
    assert overlay.state == GuidanceOverlay.STATE_MOVING

    # Advance past 600ms (movement completes, pauses at target)
    monkeypatch.setattr(time, "monotonic", lambda: start_time + 0.65)
    overlay._on_tick()
    assert overlay.state == GuidanceOverlay.STATE_PAUSE
    assert overlay.current_cursor_pt.x() == 250
    assert overlay.current_cursor_pt.y() == 300

    # Advance past 400ms pause -> transitions to trailing mode
    monkeypatch.setattr(time, "monotonic", lambda: start_time + 1.1)
    overlay._on_tick()
    assert overlay.state == GuidanceOverlay.STATE_TRAILING

    # In trailing mode, cursor follows the user's cursor while target stays fixed
    overlay._on_tick()
    assert overlay.target_pt.x() == 250
    assert overlay.target_pt.y() == 300

    # Clear guidance
    overlay.clear_guidance()
    assert overlay.is_guidance_active() is False
    assert overlay.isHidden()


def test_screen_capture_permission_denial(monkeypatch):
    monkeypatch.setattr(capture, "has_screen_recording_permission", lambda: False)
    with pytest.raises(PermissionError, match="Screen Recording permission is required"):
        capture.capture_snapshot()


def test_windows_capture_permissions_are_available_without_macos_tcc(monkeypatch):
    monkeypatch.setattr(capture, "_is_windows", lambda: True)

    assert capture.has_screen_recording_permission() is True
    assert capture.has_accessibility_permission() is True


def test_windows_active_display_uses_foreground_window_center(qapp, monkeypatch):
    monkeypatch.setattr(capture, "_is_windows", lambda: True)
    monkeypatch.setattr(capture, "_windows_foreground_center", lambda: QGuiApplication.primaryScreen().geometry().center())

    assert capture.get_active_display() == QGuiApplication.primaryScreen()


def test_screen_capture_on_demand_and_transient_purge(monkeypatch):
    mock_png = b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDRtest"
    mock_meta = {
        "display_id": 0,
        "bounds": {"x": 0, "y": 0, "width": 1920, "height": 1080},
        "scale": 2.0,
        "capture_time": time.time(),
    }

    # Simulate companion responding to desktop job in background
    def companion_worker():
        for _ in range(50):
            jobs = state.claim_desktop_jobs()
            if jobs:
                for job in jobs:
                    if job["kind"] == "screen_snapshot":
                        state.complete_desktop_job(job["job_id"], result=mock_meta, blob=mock_png)
                        return
            time.sleep(0.05)

    worker = threading.Thread(target=companion_worker)
    worker.start()

    # MCP server calls screen_snapshot
    result = server.screen_snapshot()
    worker.join()

    assert len(result) == 2
    info, image_content = result[0], result[1]
    assert info["display_id"] == 0
    assert info["scale"] == 2.0
    assert image_content.mime_type == "image/png"
    assert image_content.data == base64.b64encode(mock_png).decode("ascii")

    # Verify transient blob was purged from sqlite
    with state._db() as connection:
        count = connection.execute("SELECT count(*) as c FROM desktop_jobs").fetchone()["c"]
        assert count == 0

    # Verify screen image is NOT in SQLite action history
    history = state.recent_history()
    for row in history:
        assert "blob" not in row
        assert "data" not in row
        assert "image" not in row


def test_unavailable_companion_timeout():
    job_id = state.queue_desktop_job("screen_snapshot", {})
    with pytest.raises(TimeoutError, match="Desktop companion did not complete"):
        server._wait_for_desktop_job(job_id, timeout=0.1)


def test_stale_jobs_purged(monkeypatch):
    job_id = state.queue_desktop_job("screen_snapshot", {})
    now = time.time()
    monkeypatch.setattr(time, "time", lambda: now + state.JOB_TTL + 5)

    # Calling claim_desktop_jobs triggers _expire which cleans up jobs > JOB_TTL
    jobs = state.claim_desktop_jobs()
    assert jobs == []
    with state._db() as connection:
        row = connection.execute("SELECT * FROM desktop_jobs WHERE token = ?", (job_id,)).fetchone()
        assert row is None


def test_emergency_stop_clears_guidance_and_cancels_jobs(qapp):
    overlay = GuidanceOverlay()
    overlay.show_guidance(display_id=0, x=100, y=100)
    assert overlay.is_guidance_active() is True

    # Queue a job
    job_id = state.queue_desktop_job("show_guidance", {"x": 50, "y": 50})

    # Trigger emergency stop
    state.set_emergency_stop(True)
    overlay.clear_guidance()

    assert overlay.is_guidance_active() is False

    # Check that job status was cancelled
    with state._db() as connection:
        row = connection.execute("SELECT status FROM desktop_jobs WHERE token = ?", (job_id,)).fetchone()
        assert row["status"] == "cancelled"

    # Future jobs (except clear_guidance) rejected
    with pytest.raises(PermissionError, match="Emergency stop"):
        state.queue_desktop_job("show_guidance", {"x": 50, "y": 50})

    # clear_guidance is permitted even during emergency stop
    clear_token = state.queue_desktop_job("clear_guidance", {})
    assert clear_token is not None
