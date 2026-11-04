# Path: src/laptop_bridge/guidance_workspace.py
"""A bounded, user-dismissible canvas controlled by authenticated RelayOS tools.

Content is in memory, never persisted to disk. A native Mac window polls the
local token-protected endpoint; public MCP clients can only mutate validated
drawing primitives when Screen Guidance is enabled.
"""
from __future__ import annotations

import math
import secrets
import threading
import time

from . import state
from .config import load_config

_lock = threading.RLock()
_board = None
MAX_ELEMENTS = 200
MAX_DURATION = 3600
PALETTE = frozenset({"accent", "white", "black", "red", "green", "blue", "yellow", "orange", "purple"})
KINDS = frozenset({"text", "code", "rect", "ellipse", "line", "arrow", "path"})
WIDTH = 1000
HEIGHT = 1200


def _require_permission():
    if state.emergency_stop() or not load_config().get("capabilities", {}).get("screen_guidance", False):
        raise PermissionError("Enable Screen Guidance in RelayOS and disable Emergency Stop")


def _get():
    global _board
    if _board is not None and time.time() >= _board["expires_at"]:
        _board = None
    if state.emergency_stop() or not load_config().get("capabilities", {}).get("screen_guidance", False):
        _board = None
    return _board


def current():
    with _lock:
        board = _get()
        return dict(board) if board is not None else {"active": False, "visible": False, "revision": 0}


def open_board(title="RelayOS Notepad", duration_seconds=3600):
    _require_permission()
    if not isinstance(title, str) or not 1 <= len(title.strip()) <= 100:
        raise ValueError("Title must contain 1..100 characters")
    if isinstance(duration_seconds, bool) or not isinstance(duration_seconds, int) or not 60 <= duration_seconds <= MAX_DURATION:
        raise ValueError("duration_seconds must be 60..3600")
    global _board
    with _lock:
        _board = {
            "active": True, "visible": True, "id": secrets.token_urlsafe(14),
            "title": title.strip(), "width": WIDTH, "height": HEIGHT,
            "expires_at": time.time() + duration_seconds,
            "revision": 1, "elements": [],
        }
        return current()


def _number(value, name, minimum=0, maximum=1):
    if (isinstance(value, bool) or not isinstance(value, (int, float)) or
            not math.isfinite(value) or not minimum <= value <= maximum):
        raise ValueError(f"{name} must be finite and between {minimum} and {maximum}")
    return float(value)


def _validate(raw):
    if not isinstance(raw, dict):
        raise ValueError("Each drawing element must be an object")
    kind = raw.get("kind")
    if kind not in KINDS:
        raise ValueError("kind must be text, code, rect, ellipse, line, arrow or path")
    x = _number(raw.get("x", 0), "x")
    y = _number(raw.get("y", 0), "y")
    color = raw.get("color", "accent")
    if color not in PALETTE:
        raise ValueError("Unsupported color")
    item = {
        "id": secrets.token_hex(10), "kind": kind, "x": x, "y": y,
        "color": color, "stroke_width": _number(raw.get("stroke_width", 3), "stroke_width", 1, 12),
    }
    if kind in {"text", "code"}:
        value = raw.get("text")
        if not isinstance(value, str) or not value.strip() or len(value) > 2500:
            raise ValueError("Text must contain 1..2500 characters")
        item["text"] = value
        item["font_size"] = _number(raw.get("font_size", 20), "font_size", 10, 40)
        item["w"] = _number(raw.get("w", .5), "w", .05, 1)
        if x + item["w"] > 1.00001:
            raise ValueError("Text exceeds canvas width")
    elif kind == "path":
        points = raw.get("points")
        if not isinstance(points, list) or not 2 <= len(points) <= 96:
            raise ValueError("Path requires 2..96 points")
        clean = []
        for point in points:
            if not isinstance(point, (list, tuple)) or len(point) != 2:
                raise ValueError("Each path point requires [x, y]")
            clean.append([_number(point[0], "point.x"), _number(point[1], "point.y")])
        item["points"] = clean
    else:
        w = _number(raw.get("w"), "w", 0.001, 1)
        h = _number(raw.get("h"), "h", 0.001, 1)
        if x + w > 1.00001 or y + h > 1.00001:
            raise ValueError("Shape exceeds canvas")
        item["w"], item["h"] = w, h
    return item


def add_elements(board_id, elements):
    _require_permission()
    if not isinstance(elements, list) or not 1 <= len(elements) <= 30:
        raise ValueError("Supply 1..30 elements per call")
    validated = [_validate(e) for e in elements]
    with _lock:
        board = _matching(board_id)
        if len(board["elements"]) + len(validated) > MAX_ELEMENTS:
            raise ValueError("Notepad has reached its 200-element limit")
        board["elements"].extend(validated)
        board["revision"] += 1
        return {"added_ids": [e["id"] for e in validated], "revision": board["revision"],
                "total_elements": len(board["elements"])}


def _matching(board_id):
    board = _get()
    if board is None or board["id"] != board_id:
        raise PermissionError("Notepad is not active or the board ID is incorrect")
    return board


def edit_board(board_id, action, element_ids=None):
    _require_permission()
    if action not in {"show", "hide", "clear", "remove", "close"}:
        raise ValueError("Action must be show, hide, clear, remove or close")
    global _board
    with _lock:
        board = _matching(board_id)
        if action == "remove":
            if not isinstance(element_ids, list) or not 1 <= len(element_ids) <= 50:
                raise ValueError("Select 1..50 drawing element IDs")
            ids = set(element_ids)
            board["elements"] = [e for e in board["elements"] if e["id"] not in ids]
        elif action == "clear":
            board["elements"].clear()
        elif action in {"show", "hide"}:
            board["visible"] = action == "show"
        elif action == "close":
            _board = None
            return {"active": False, "visible": False}
        board["revision"] += 1
        return {"active": True, "visible": board["visible"], "revision": board["revision"],
                "total_elements": len(board["elements"])}


def local_action(action):
    """Used only through the authenticated loopback control endpoint."""
    with _lock:
        board = _get()
        if board is None:
            return {"active": False}
        return edit_board(board["id"], action)


def revoke():
    global _board
    with _lock:
        _board = None
