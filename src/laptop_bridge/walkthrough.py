# Path: src/laptop_bridge/walkthrough.py
"""Local, observation-driven RelayOS guidance. No screenshots or input injection.

MCP can start a fixed recipe, but only the authenticated native companion can
report progress. No timer or model response advances an unverified step.
"""
from __future__ import annotations

import math
import secrets
import threading
import time

from . import cursor_guidance, state

_lock = threading.RLock()
_current: dict | None = None
FLOW = "system_settings_general"
BUNDLE_ID = "com.apple.systempreferences"
MAX_SECONDS = 900
NUDGE_SECONDS = 45

STEPS = (
    "Open System Settings using the Apple menu at the top-left of your Mac.",
    "Click General in the System Settings sidebar.",
)


def _require_available() -> None:
    if not cursor_guidance._permitted() or state.emergency_stop():
        raise PermissionError("Enable Screen Guidance in RelayOS and turn off Emergency Stop")


def _visible(session: dict, now: float) -> dict:
    if session["status"] == "active" and now >= session["deadline"]:
        session["status"] = "expired"
        cursor_guidance.clear()
    if session["status"] == "active" and now - session["step_started"] >= NUDGE_SECONDS:
        session["attention_needed"] = True
    return {
        "id": session["id"], "flow": FLOW, "status": session["status"],
        "step": session["step"], "total_steps": len(STEPS),
        "instruction": (STEPS[session["step"]] if session["step"] < len(STEPS) else
                        "Done: System Settings → General is open."),
        "attention_needed": session["attention_needed"],
        "expires_in_seconds": max(0, math.ceil(session["deadline"] - now)) if session["status"] in ("active", "paused") else 0,
    }


def _step_message(session: dict) -> str:
    if session.get("last_focus") is False and session["step"] == 1:
        return "Return to System Settings to continue. I'll show the next control there."
    if session.get("accessibility") is False and session["step"] == 1:
        return ("Click General in System Settings. For automatic verification, "
                "enable RelayOS in Privacy & Security > Accessibility.")
    if session["attention_needed"]:
        return "Still waiting: " + STEPS[session["step"]]
    return STEPS[session["step"]]


def _publish_tip(session: dict, text: str | None = None) -> None:
    message = text or _step_message(session)
    cursor_guidance.show_tip(message, min(60, max(1, session["deadline"] - time.time())))


def start(flow: str = FLOW, duration_seconds: int = 600) -> dict:
    _require_available()
    if flow != FLOW:
        raise ValueError("Unsupported walkthrough. Available: system_settings_general")
    if isinstance(duration_seconds, bool) or not isinstance(duration_seconds, int) or not 60 <= duration_seconds <= MAX_SECONDS:
        raise ValueError("duration_seconds must be 60..900")
    global _current
    with _lock:
        now = time.time()
        cursor_guidance.clear()
        _current = {
            "id": secrets.token_hex(12), "flow": flow, "status": "active",
            "step": 0, "deadline": now + duration_seconds, "step_started": now,
            "attention_needed": False, "last_target": None, "last_tip": now,
            "accessibility": None, "last_focus": None,
        }
        _publish_tip(_current)
        return _visible(_current, now)


def status() -> dict:
    global _current
    with _lock:
        if _current is None:
            return {"status": "idle", "active": False, "flow": None}
        if not cursor_guidance._permitted() or state.emergency_stop():
            _current["status"] = "stopped"
            cursor_guidance.clear()
        now = time.time()
        info = _visible(_current, now)
        info["active"] = info["status"] == "active"
        if info["status"] == "active":
            # Restore the current instruction after its 60-second tip timeout,
            # or repeat a reminder after inactivity. Never advance on time.
            tip = cursor_guidance.current_target().get("tip")
            if tip is None and now - _current["last_tip"] >= 2:
                _publish_tip(_current)
                _current["last_tip"] = now
        return info


def control(action: str, session_id: str | None = None) -> dict:
    global _current
    if action not in {"pause", "resume", "stop"}:
        raise ValueError("action must be pause, resume or stop")
    with _lock:
        if _current is None or (session_id is not None and session_id != _current["id"]):
            raise PermissionError("No matching walkthrough session")
        if action == "stop":
            _current["status"] = "stopped"
            cursor_guidance.clear()
        elif action == "pause" and _current["status"] == "active":
            _current["status"] = "paused"
            cursor_guidance.clear()
        elif action == "resume" and _current["status"] == "paused":
            _require_available()
            if time.time() >= _current["deadline"]:
                _current["status"] = "expired"
            else:
                _current["status"] = "active"
                _current["last_target"] = None
                _publish_tip(_current)
        return status()


def observe(session_id: str, frontmost_bundle_id: str, *,
            general_selected: bool = False, accessibility: bool = False,
            general_bounds: list[float] | None = None) -> dict:
    """Advance only on a native observation; do not trust arbitrary MCP input.

    Bounds are screen-normalized from a locally discovered Accessibility element,
    not estimated from a screenshot and not used until the correct app is focused.
    """
    global _current
    if not isinstance(frontmost_bundle_id, str) or len(frontmost_bundle_id) > 128:
        raise ValueError("Invalid app identifier")
    if not isinstance(general_selected, bool) or not isinstance(accessibility, bool):
        raise ValueError("Observations must be booleans")
    with _lock:
        info = status()
        if (_current is None or not isinstance(session_id, str) or
                not secrets.compare_digest(session_id, _current["id"]) or
                info["status"] != "active"):
            raise PermissionError("Walkthrough is missing, stopped, paused or expired")
        if frontmost_bundle_id != BUNDLE_ID:
            if _current["step"] == 1 and _current["last_focus"] is not False:
                cursor_guidance.clear()
                _current["last_focus"] = False
                _current["last_target"] = None
                _publish_tip(_current)
                _current["last_tip"] = time.time()
            return info
        now = time.time()
        if _current["step"] == 1 and _current["last_focus"] is False:
            cursor_guidance.clear()
            _current["last_focus"] = True
            _current["last_target"] = None
            _publish_tip(_current)
            _current["last_tip"] = now
        if _current["step"] == 0:
            _current["step"] = 1
            _current["last_focus"] = True
            _current["step_started"] = now
            _current["attention_needed"] = False
            _current["last_target"] = None
            _publish_tip(_current)
            _current["last_tip"] = now
        if _current["step"] != 1:
            return status()
        if _current["accessibility"] is not accessibility and not accessibility:
            cursor_guidance.clear()
            _current["last_target"] = None
            _current["accessibility"] = False
            _publish_tip(_current)
        _current["accessibility"] = accessibility
        if general_selected and accessibility:
            _current["step"] = len(STEPS)
            _current["status"] = "completed"
            _current["attention_needed"] = False
            cursor_guidance.clear()
            cursor_guidance.show_tip("Completed! System Settings → General is open.", 15)
            return status()
        if general_bounds is not None and accessibility:
            if (not isinstance(general_bounds, list) or len(general_bounds) != 4 or
                    any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v)
                        for v in general_bounds)):
                raise ValueError("Invalid target bounds")
            x, y, w, h = general_bounds
            if not (0 <= x <= 1 and 0 <= y <= 1 and 0 < w <= 1 and 0 < h <= 1 and
                    x + w <= 1 and y + h <= 1):
                raise ValueError("Target bounds outside main display")
            placement = [round(v, 3) for v in general_bounds]
            if placement != _current["last_target"]:
                cursor_guidance.highlight_region(
                    "rounded_rect", x, y, w, h, hold_seconds=60,
                    proximity_radius=9, tip=STEPS[1])
                _current["last_target"] = placement
                _current["last_tip"] = now
        return status()


def revoke() -> None:
    global _current
    with _lock:
        if _current and _current["status"] in ("active", "paused"):
            _current["status"] = "stopped"
        cursor_guidance.clear()
