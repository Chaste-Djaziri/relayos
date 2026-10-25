"""Passive global click observation for active guidance sessions."""

import ctypes
import os
import time


class ClickObserver:
    """Observe global mouse clicks without injecting or replaying input."""

    def __init__(self, on_click):
        self.on_click = on_click
        self._monitor = None
        self._listener = None
        self.available = False
        self._windows_mouse = None
        if os.name == "nt":
            try:
                from pynput import mouse
                self._windows_mouse = mouse
                self.available = True
            except ImportError:
                pass
            return
        try:
            from AppKit import NSEvent, NSLeftMouseDown, NSRightMouseDown, NSOtherMouseDown
            self._NSEvent = NSEvent
            self._event_types = NSLeftMouseDown | NSRightMouseDown | NSOtherMouseDown
            self.available = True
        except ImportError:
            pass

    def start(self):
        if not self.available:
            return False
        if self._windows_mouse is not None:
            if self._listener is not None:
                return True

            def handle(x, y, button, pressed):
                if not pressed:
                    return
                name = getattr(button, "name", str(button).removeprefix("Button."))
                self.on_click(float(x), float(y), name, _windows_modifiers(), time.time())

            self._listener = self._windows_mouse.Listener(on_click=handle)
            self._listener.start()
            return True
        if self._monitor is not None:
            return True

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
        if self._listener is not None:
            self._listener.stop()
            self._listener = None
        if self._monitor is not None:
            self._NSEvent.removeMonitor_(self._monitor)
            self._monitor = None


def _windows_modifiers():
    """Read only modifier state for a mouse event; never record key content."""
    if os.name != "nt" or not hasattr(ctypes, "windll"):
        return []
    try:
        user32 = ctypes.windll.user32
        keys = ((0x10, "shift"), (0x11, "control"), (0x12, "alt"), (0x5B, "command"))
        return [name for key, name in keys if user32.GetAsyncKeyState(key) & 0x8000]
    except Exception:
        return []
