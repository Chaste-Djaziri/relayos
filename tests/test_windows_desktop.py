from PySide6.QtWidgets import QApplication, QMainWindow

from laptop_bridge import desktop
from laptop_bridge import windows_setup


class FakeOverlay:
    def clear_guidance(self):
        return None


class FakeObserver:
    def __init__(self, _callback):
        self.stopped = False

    def stop(self):
        self.stopped = True


def test_windows_companion_uses_visible_window_without_tray(monkeypatch):
    app = QApplication.instance() or QApplication([])
    shown = []
    monkeypatch.setattr(desktop, "_is_windows", lambda: True)
    monkeypatch.setattr(desktop, "GuidanceOverlay", FakeOverlay)
    monkeypatch.setattr(desktop, "ClickObserver", FakeObserver)
    monkeypatch.setattr(desktop, "StatusWindow", lambda _companion: QMainWindow())
    monkeypatch.setattr(desktop, "load_config", lambda: {"setup_complete": True})
    monkeypatch.setattr(desktop.Companion, "start_server", lambda self: None)
    monkeypatch.setattr(desktop.Companion, "show_window", lambda self: shown.append(True))
    monkeypatch.setattr(desktop.Companion, "_create_tray", lambda self: (_ for _ in ()).throw(AssertionError("tray must not be created")))

    companion = desktop.Companion(app)

    assert shown == [True]
    assert companion.tray is None
    assert companion.quick_panel is None
    companion.shutdown()
    assert companion.click_observer.stopped is True


def test_windows_prerequisites_start_winget_for_missing_tools(monkeypatch):
    calls = []
    monkeypatch.setattr(windows_setup, "is_windows", lambda: True)
    monkeypatch.setattr(windows_setup.ngrok, "find_executable", lambda: None)
    monkeypatch.setattr(windows_setup.shutil, "which", lambda name: "C:/winget.exe" if name == "winget" else None)
    monkeypatch.setattr(windows_setup.subprocess, "Popen", lambda args, **kwargs: calls.append(args))
    result = windows_setup.provision_prerequisites()
    assert result["started"] == ["9MVS1J51GMK6", "Git.Git"]
    assert calls[0][0:3] == ["C:/winget.exe", "install", "--id"]
    assert "--source" in calls[0] and "msstore" in calls[0]
    assert "--source" in calls[1] and "winget" in calls[1]
