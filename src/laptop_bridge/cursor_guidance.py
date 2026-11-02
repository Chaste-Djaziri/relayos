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
MAX_TIP_CHARS = 240
_lock = threading.Lock()
_active: dict | None = None
_tip: dict | None = None


def _validate_tip(message: str | None) -> str | None:
    if message is None:
        return None
    if not isinstance(message, str):
        raise ValueError("Tip message must be a string")
    clean = message.strip()
    if not clean or len(clean) > MAX_TIP_CHARS or len(clean.encode("utf-8")) > 1000:
        raise ValueError("Tip message must be 1..240 characters (max 1000 UTF-8 bytes)")
    if any(ord(ch) < 32 and ch not in "\\n\\t" for ch in clean) or clean.count("\\n") > 3:
        raise ValueError("Tip message contains unsupported control characters")
    return clean


def _make_tip(message: str, expires_at: float, target_id: str | None = None) -> dict:
    return {"id": secrets.token_hex(12), "text": message,
            "expires_at": expires_at, "target_id": target_id}


def show_tip(message: str, hold_seconds: float = 20) -> dict:
    """Display a short ephemeral typewritten tip beside the *virtual* cursor."""
    if not _permitted():
        raise PermissionError("Screen Guidance is disabled or Emergency Stop is enabled")
    clean = _validate_tip(message)
    if clean is None:
        raise ValueError("Tip message is required")
    hold = _number(hold_seconds, "hold_seconds", 1, MAX_HOLD_SECONDS)
    global _tip
    with _lock:
        _tip = _make_tip(clean, time.time() + hold)
    return {"displaying": True, "hold_seconds": hold,
            "message": "RelayOS will type the tip beside its virtual cursor. No click is generated."}


def clear_tip() -> dict:
    global _tip
    with _lock:
        _tip = None
    return {"cleared": True}



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


def point_to(x: float, y: float, display: str = "main", hold_seconds: float = 20,
             tip: str | None = None) -> dict:
    """Set a bounded target; x and y are 0..1 in top-left screenshot space."""
    if not _permitted():
        raise PermissionError("Screen Guidance is disabled or Emergency Stop is enabled")
    if any(isinstance(v, bool) or not isinstance(v, (int, float)) or
           not math.isfinite(v) or not 0 <= v <= 1 for v in (x, y)):
        raise ValueError("x and y must be finite normalized coordinates in [0, 1]")
    if isinstance(hold_seconds, bool) or not isinstance(hold_seconds, (int, float)) or not math.isfinite(hold_seconds) or not 1 <= hold_seconds <= MAX_HOLD_SECONDS:
        raise ValueError("hold_seconds must be between 1 and 60")
    display = _display(display)
    tip_text = _validate_tip(tip)
    event = {
        "id": secrets.token_hex(12),
        "display": display,
        "x": float(x),
        "y": float(y),
        "expires_at": time.time() + float(hold_seconds),
    }
    global _active, _tip
    with _lock:
        _active = event
        _tip = _make_tip(tip_text, event["expires_at"], event["id"]) if tip_text else None
    return {"pointing": True, "display": display, "x": float(x), "y": float(y),
            "hold_seconds": float(hold_seconds),
            "message": "RelayOS virtual cursor will point at the location. No mouse input or click is generated."}



# Screen regions are constrained to a single display and passed verbatim only
# to the authenticated native companion; no screen content or pixels are stored.
REGION_SHAPES = frozenset({"rect", "rounded_rect", "ellipse"})
PATH_SHAPES = frozenset({"polygon", "path"})
MAX_POINTS = 96


def _number(value, name: str, minimum: float, maximum: float) -> float:
    if (isinstance(value, bool) or not isinstance(value, (int, float)) or
            not math.isfinite(value) or not minimum <= value <= maximum):
        raise ValueError(f"{name} must be finite and within [{minimum}, {maximum}]")
    return float(value)


def _visual_options(hold_seconds, proximity_radius, show_cursor,
                    fill_opacity, stroke_width) -> dict:
    hold = _number(hold_seconds, "hold_seconds", 1, MAX_HOLD_SECONDS)
    radius = _number(proximity_radius, "proximity_radius", 0, 200)
    opacity = _number(fill_opacity, "fill_opacity", 0, 0.25)
    stroke = _number(stroke_width, "stroke_width", 1, 6)
    if not isinstance(show_cursor, bool):
        raise ValueError("show_cursor must be a boolean")
    return dict(hold_seconds=hold, proximity_radius=radius, show_cursor=show_cursor,
                fill_opacity=opacity, stroke_width=stroke)


def _publish_highlight(display: str, region: dict, anchor: tuple[float, float],
                       settings: dict, tip: str | None = None) -> dict:
    if not _permitted():
        raise PermissionError("Screen Guidance is disabled or Emergency Stop is enabled")
    event = {
        "id": secrets.token_hex(12), "display": _display(display),
        "x": anchor[0], "y": anchor[1],
        "expires_at": time.time() + settings["hold_seconds"],
        "region": region,
        "proximity_radius": settings["proximity_radius"],
        "show_cursor": settings["show_cursor"],
    }
    tip_text = _validate_tip(tip)
    global _active, _tip
    with _lock:
        _active = event
        _tip = _make_tip(tip_text, event["expires_at"], event["id"]) if tip_text else None
    return {"highlighting": True, "shape": region["shape"],
            "display": event["display"], "hold_seconds": settings["hold_seconds"],
            "proximity_radius": settings["proximity_radius"],
            "message": "RelayOS draws a temporary click-through highlight; no OS input is generated."}


def highlight_region(shape: str, x: float, y: float, width: float, height: float,
                     display: str = "main", hold_seconds: float = 20,
                     proximity_radius: float = 48, show_cursor: bool = True,
                     fill_opacity: float = 0.12, stroke_width: float = 2.5,
                     corner_radius: float = 10, tip: str | None = None) -> dict:
    """Highlight a rectangle, rounded rectangle or ellipse on a display."""
    if shape not in REGION_SHAPES:
        raise ValueError("shape must be rect, rounded_rect or ellipse")
    left = _number(x, "x", 0, 1)
    top = _number(y, "y", 0, 1)
    w = _number(width, "width", 0, 1)
    h = _number(height, "height", 0, 1)
    if w == 0 or h == 0 or left + w > 1.000000001 or top + h > 1.000000001:
        raise ValueError("Region must have positive area fully within the display")
    corner = _number(corner_radius, "corner_radius", 0, 40)
    settings = _visual_options(hold_seconds, proximity_radius, show_cursor,
                               fill_opacity, stroke_width)
    region = {"shape": shape, "bounds": [left, top, w, h],
              "points": [], "closed": True, "corner_radius": corner,
              "fill_opacity": settings["fill_opacity"],
              "stroke_width": settings["stroke_width"]}
    return _publish_highlight(display, region, (left + w / 2, top + h / 2), settings, tip)


def highlight_path(points: list[list[float]], shape: str = "polygon",
                   display: str = "main", hold_seconds: float = 20,
                   proximity_radius: float = 48, show_cursor: bool = True,
                   fill_opacity: float = 0.12, stroke_width: float = 2.5,
                   closed: bool | None = None, tip: str | None = None) -> dict:
    """Highlight a polygon or open/closed freeform polyline. 2–96 vertices."""
    if shape not in PATH_SHAPES:
        raise ValueError("shape must be polygon or path")
    if not isinstance(points, list) or not 2 <= len(points) <= MAX_POINTS:
        raise ValueError("Provide 2 to 96 points")
    if shape == "polygon" and len(points) < 3:
        raise ValueError("A polygon needs at least three points")
    if closed is None:
        closed = shape == "polygon"
    if not isinstance(closed, bool) or (shape == "polygon" and not closed):
        raise ValueError("Polygon must be closed; path closed must be boolean")
    clean = []
    for point in points:
        if not isinstance(point, (list, tuple)) or len(point) != 2:
            raise ValueError("Each point must contain x and y")
        clean.append([_number(point[0], "point.x", 0, 1),
                      _number(point[1], "point.y", 0, 1)])
    if len(set(map(tuple, clean))) < (3 if closed else 2):
        raise ValueError("Path requires distinct points")
    settings = _visual_options(hold_seconds, proximity_radius, show_cursor,
                               fill_opacity, stroke_width)
    left, right = min(v[0] for v in clean), max(v[0] for v in clean)
    top, bottom = min(v[1] for v in clean), max(v[1] for v in clean)
    region = {"shape": shape, "bounds": [left, top, right-left, bottom-top],
              "points": clean, "closed": closed, "corner_radius": 0.,
              "fill_opacity": settings["fill_opacity"] if closed else 0.,
              "stroke_width": settings["stroke_width"]}
    return _publish_highlight(display, region,
                              ((left + right)/2, (top + bottom)/2), settings, tip)

def current_target() -> dict:
    """Read for the authenticated *local* native cursor poller."""
    global _active, _tip
    if not _permitted():
        clear()
        return {"active": False}
    with _lock:
        now = time.time()
        if _active is not None and now >= _active["expires_at"]:
            _active = None
        if _tip is not None and (now >= _tip["expires_at"] or
                (_tip["target_id"] is not None and
                 (_active is None or _active["id"] != _tip["target_id"]))):
            _tip = None
        result = {"active": True, **_active} if _active is not None else {"active": False}
        if _tip is not None:
            result["tip"] = _tip.copy()
        return result


def complete_target(target_id: str) -> dict:
    """Dismiss only the target that the user's real pointer reached.

    A delayed acknowledgement must never cancel a newer guidance target.
    """
    global _active, _tip
    if not isinstance(target_id, str) or not 1 <= len(target_id) <= 128:
        raise ValueError("Invalid cursor guidance id")
    with _lock:
        if _active is not None and secrets.compare_digest(_active["id"], target_id):
            _active = None
            if _tip is not None and _tip["target_id"] == target_id:
                _tip = None
            return {"cleared": True}
    return {"cleared": False}


def clear() -> dict:
    global _active, _tip
    with _lock:
        _active = None
        _tip = None
    return {"cleared": True}
