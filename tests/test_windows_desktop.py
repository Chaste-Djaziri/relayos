from PySide6.QtWidgets import QApplication, QMainWindow

from laptop_bridge import desktop


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
