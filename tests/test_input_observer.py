from laptop_bridge import input_observer


class FakeListener:
    def __init__(self, on_click):
        self.on_click = on_click
        self.started = False
        self.stopped = False

    def start(self):
        self.started = True

    def stop(self):
        self.stopped = True


class FakeMouse:
    Listener = FakeListener


def test_windows_observer_reports_pressed_clicks_only(monkeypatch):
    events = []
    monkeypatch.setattr(input_observer, "_windows_modifiers", lambda: ["shift"])
    observer = input_observer.ClickObserver(lambda *event: events.append(event))
    observer.available = True
    observer._windows_mouse = FakeMouse

    assert observer.start() is True
    observer._listener.on_click(20, 30, type("Button", (), {"name": "left"})(), False)
    observer._listener.on_click(20, 30, type("Button", (), {"name": "left"})(), True)

    assert len(events) == 1
    assert events[0][:4] == (20.0, 30.0, "left", ["shift"])
    observer.stop()
    assert observer._listener is None
