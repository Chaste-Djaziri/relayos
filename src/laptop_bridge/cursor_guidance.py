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
                       settings: dict) -> dict:
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
    global _active
    with _lock:
        _active = event
    return {"highlighting": True, "shape": region["shape"],
            "display": event["display"], "hold_seconds": settings["hold_seconds"],
            "proximity_radius": settings["proximity_radius"],
            "message": "RelayOS draws a temporary click-through highlight; no OS input is generated."}


def highlight_region(shape: str, x: float, y: float, width: float, height: float,
                     display: str = "main", hold_seconds: float = 20,
                     proximity_radius: float = 48, show_cursor: bool = True,
                     fill_opacity: float = 0.12, stroke_width: float = 2.5,
                     corner_radius: float = 10) -> dict:
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
    return _publish_highlight(display, region, (left + w / 2, top + h / 2), settings)


def highlight_path(points: list[list[float]], shape: str = "polygon",
                   display: str = "main", hold_seconds: float = 20,
                   proximity_radius: float = 48, show_cursor: bool = True,
                   fill_opacity: float = 0.12, stroke_width: float = 2.5,
                   closed: bool | None = None) -> dict:
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
                              ((left + right)/2, (top + bottom)/2), settings)

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
