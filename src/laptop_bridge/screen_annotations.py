# Path: src/laptop_bridge/screen_annotations.py
"""Multi-element visual annotations placed DIRECTLY above a macOS display.

This is a time-limited, in-memory drawing plane separate from the teaching
notepad. Drawing primitives carry only normalized coordinates and plain text.
No screenshot, input stream, file content, or foreground app data is collected.
"""
from __future__ import annotations

import math
import secrets
import threading
import time

from . import cursor_guidance

_lock = threading.RLock()
_items: list[dict] = []
_revision = 0
MAX_ITEMS = 200
MAX_PER_CALL = 40
MAX_SECONDS = 900
KINDS = frozenset({"label", "text", "code", "rect", "ellipse", "arrow", "line", "path", "scribble"})
COLORS = frozenset({"accent", "white", "black", "red", "green", "blue", "yellow", "orange", "purple"})


def _permitted():
    if not cursor_guidance._permitted():
        revoke()
        raise PermissionError("Enable Screen Guidance and disable Emergency Stop in RelayOS")


def _num(value, label, minimum=0., maximum=1.):
    if (isinstance(value, bool) or not isinstance(value, (int, float))
            or not math.isfinite(value) or not minimum <= value <= maximum):
        raise ValueError(f"{label} must be finite and between {minimum} and {maximum}")
    return float(value)


def _clean(raw: dict, display: str, now: float, duration_seconds: int) -> dict:
    if not isinstance(raw, dict) or raw.get("kind") not in KINDS:
        raise ValueError(f"kind must be one of: {', '.join(sorted(KINDS))}")
    kind = raw["kind"]
    color = raw.get("color", "accent")
    if color not in COLORS:
        raise ValueError("Unsupported annotation color")
    x = _num(raw.get("x"), "x")
    y = _num(raw.get("y"), "y")
    width = raw.get("w", None)
    height = raw.get("h", None)
    item = {
        "id": secrets.token_hex(12), "kind": kind, "display": display,
        "x": x, "y": y, "color": color,
        "stroke_width": _num(raw.get("stroke_width", 3), "stroke_width", 1, 10),
        "expires_at": now + duration_seconds,
        "opacity": _num(raw.get("opacity", 1), "opacity", 0.2, 1),
    }
    if kind in ("label", "text", "code"):
        value = raw.get("text")
        if not isinstance(value, str) or not value.strip() or len(value) > 2000 or "\x00" in value:
            raise ValueError("Text must contain 1..2000 plain characters")
        if any(ord(ch) < 32 and ch not in "\n\t" for ch in value):
            raise ValueError("Text contains control characters")
        item["text"] = value
        item["font_size"] = _num(raw.get("font_size", 18), "font_size", 10, 40)
        item["w"] = _num(raw.get("w", .20), "w", .025, 1)
        item["h"] = 0.
        if x + item["w"] > 1.00000001:
            raise ValueError("Text exceeds display width")
    elif kind in ("path", "scribble"):
        points = raw.get("points")
        if not isinstance(points, list) or not 2 <= len(points) <= 128:
            raise ValueError("A path requires 2..128 normalized [x,y] points")
        clean_points = []
        for point in points:
            if not isinstance(point, (list, tuple)) or len(point) != 2:
                raise ValueError("Invalid path point")
            clean_points.append([_num(point[0], "point.x"), _num(point[1], "point.y")])
        if len(set(map(tuple, clean_points))) < 2:
            raise ValueError("Path requires two distinct points")
        item["points"] = clean_points
        item["w"] = item["h"] = 0.
    else:
        # Arrow and line draw between two points: (x,y) -> (x+w,y+h).
        # The vector can be negative to point left or upward.
        if kind in ("arrow", "line"):
            item["w"] = _num(width, "w", -1, 1)
            item["h"] = _num(height, "h", -1, 1)
            if (not 0 <= x + item["w"] <= 1 or not 0 <= y + item["h"] <= 1
                    or abs(item["w"]) + abs(item["h"]) < .0001):
                raise ValueError("Line/arrow endpoint must be on display")
        else:
            item["w"] = _num(width, "w", .001, 1)
            item["h"] = _num(height, "h", .001, 1)
            if x + item["w"] > 1.00000001 or y + item["h"] > 1.00000001:
                raise ValueError("Shape exceeds display")
    app = raw.get("only_when_app")
    if app is not None:
        if not isinstance(app, str) or not 1 <= len(app) <= 150 or any(ord(c) < 33 or ord(c) > 126 for c in app):
            raise ValueError("only_when_app must be a macOS application bundle ID")
        item["only_when_app"] = app
    return item


def _prune():
    global _revision, _items
    if not cursor_guidance._permitted():
        if _items:
            _items = []
            _revision += 1
        return
    now = time.time()
    alive = [item for item in _items if item["expires_at"] > now]
    if len(alive) != len(_items):
        _items = alive
        _revision += 1


def current():
    with _lock:
        _prune()
        return {"active": bool(_items), "revision": _revision,
                "annotations": [dict(item) for item in _items]}


def draw(elements: list[dict], display="main", duration_seconds=240, replace=False):
    """Draw a set atomically. The coordinates refer to an approved FULL display frame."""
    _permitted()
    display = cursor_guidance._display(display)
    if (isinstance(duration_seconds, bool) or not isinstance(duration_seconds, int)
            or not 5 <= duration_seconds <= MAX_SECONDS):
        raise ValueError("duration_seconds must be 5..900")
    if not isinstance(replace, bool):
        raise ValueError("replace must be a boolean")
    if not isinstance(elements, list) or not 1 <= len(elements) <= MAX_PER_CALL:
        raise ValueError("Supply 1..40 elements")
    now = time.time()
    validated = [_clean(item, display, now, duration_seconds) for item in elements]
    global _revision, _items
    with _lock:
        _prune()
        remaining = [item for item in _items if not (replace and item["display"] == display)]
        if len(remaining) + len(validated) > MAX_ITEMS:
            raise ValueError("A maximum of 200 screen annotations is supported")
        _items = remaining + validated
        _revision += 1
        return {"ids": [item["id"] for item in validated],
                "revision": _revision, "count": len(_items), "display": display,
                "message": "Direct on-screen annotations queued. No notepad was opened."}


def erase(ids: list[str] | None = None, display: str | None = None):
    _permitted()
    if ids is None and display is None:
        raise ValueError("Specify annotation IDs or a display to clear")
    if ids is not None:
        if not isinstance(ids, list) or not 1 <= len(ids) <= MAX_ITEMS or not all(
                isinstance(i, str) and 1 <= len(i) <= 100 for i in ids):
            raise ValueError("ids must contain 1..200 annotation IDs")
    if display is not None:
        display = cursor_guidance._display(display)
    global _revision, _items
    with _lock:
        _prune()
        chosen = set(ids or [])
        before = len(_items)
        _items = [item for item in _items if not (
            (item["id"] in chosen) or (ids is None and item["display"] == display)
        )]
        _revision += 1
        return {"removed": before - len(_items), "remaining": len(_items), "revision": _revision}


def erase_all():
    global _revision, _items
    with _lock:
        removed = len(_items)
        _items = []
        _revision += 1
        return {"removed": removed, "remaining": 0, "revision": _revision}


def revoke():
    erase_all()
