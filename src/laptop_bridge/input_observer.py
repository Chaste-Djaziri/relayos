"""Optional macOS passive click observation for active guidance sessions."""

import time


class ClickObserver:
    """Observe global mouse clicks without injecting or replaying input."""

    def __init__(self, on_click):
        self.on_click = on_click
        self._monitor = None
        self.available = False
        try:
            from AppKit import NSEvent, NSLeftMouseDown, NSRightMouseDown, NSOtherMouseDown
            self._NSEvent = NSEvent
            self._event_types = NSLeftMouseDown | NSRightMouseDown | NSOtherMouseDown
            self.available = True
        except ImportError:
            pass

    def start(self):
        if not self.available or self._monitor is not None:
            return self._monitor is not None

        def handle(event):
            location = event.locationInWindow()
            button = "left" if event.type() == 1 else "right" if event.type() == 3 else "other"
            modifiers = []
            flags = int(event.modifierFlags())
            if flags & (1 << 17):
                modifiers.append("shift")
            if flags & (1 << 18):
                modifiers.append("control")
            if flags & (1 << 19):
                modifiers.append("option")
            if flags & (1 << 20):
                modifiers.append("command")
            self.on_click(float(location.x), float(location.y), button, modifiers, time.time())

        self._monitor = self._NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(self._event_types, handle)
        return self._monitor is not None

    def stop(self):
        if self._monitor is not None:
            self._NSEvent.removeMonitor_(self._monitor)
            self._monitor = None
