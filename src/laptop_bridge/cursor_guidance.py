# Path: src/laptop_bridge/cursor_guidance.py
"""Ephemeral visual-only cursor targets for the native RelayOS companion.

A target is a point in a *display* screenshot with top-left origin; it never
moves the OS pointer, invokes clicks, or requests a new screen capture.
"""
from __future__ import annotations

import math
import secrets
import threading
import time

from . import state
from .config import load_config

MAX_HOLD_SECONDS = 60
_lock = threading.Lock()
_active: dict | None = None


def _permitted() -> bool:
    return (bool(load_config().get("capabilities", {}).get("screen_guidance", False))
            and not state.emergency_stop())


def _display(value: str) -> str:
    if not isinstance(value, str):
        raise ValueError("Display must be 'main' or a numeric CGDisplayID")
    value = value.strip()
    if value != "main" and (not value.isascii() or not value.isdecimal() or len(value) > 12):
        raise ValueError("Display must be 'main' or a numeric CGDisplayID")
    return value


def point_to(x: float, y: float, display: str = "main", hold_seconds: float = 20) -> dict:
    """Set a bounded target; x and y are 0..1 in top-left screenshot space."""
    if not _permitted():
        raise PermissionError("Screen Guidance is disabled or Emergency Stop is enabled")
    if any(isinstance(v, bool) or not isinstance(v, (int, float)) or
           not math.isfinite(v) or not 0 <= v <= 1 for v in (x, y)):
        raise ValueError("x and y must be finite normalized coordinates in [0, 1]")
    if isinstance(hold_seconds, bool) or not isinstance(hold_seconds, (int, float)) or not math.isfinite(hold_seconds) or not 1 <= hold_seconds <= MAX_HOLD_SECONDS:
        raise ValueError("hold_seconds must be between 1 and 60")
    display = _display(display)
    event = {
        "id": secrets.token_hex(12),
        "display": display,
        "x": float(x),
        "y": float(y),
        "expires_at": time.time() + float(hold_seconds),
    }
    global _active
    with _lock:
        _active = event
    return {"pointing": True, "display": display, "x": float(x), "y": float(y),
            "hold_seconds": float(hold_seconds),
            "message": "RelayOS virtual cursor will point at the location. No mouse input or click is generated."}


def current_target() -> dict:
    """Read for the authenticated *local* native cursor poller."""
    global _active
    if not _permitted():
        clear()
        return {"active": False}
    with _lock:
        if _active is None:
            return {"active": False}
        if time.time() >= _active["expires_at"]:
            _active = None
            return {"active": False}
        return {"active": True, **_active}


def complete_target(target_id: str) -> dict:
    """Dismiss only the target that the user's real pointer reached.

    A delayed acknowledgement must never cancel a newer guidance target.
    """
    global _active
    if not isinstance(target_id, str) or not 1 <= len(target_id) <= 128:
        raise ValueError("Invalid cursor guidance id")
    with _lock:
        if _active is not None and secrets.compare_digest(_active["id"], target_id):
            _active = None
            return {"cleared": True}
    return {"cleared": False}


def clear() -> dict:
    global _active
    with _lock:
        _active = None
    return {"cleared": True}
