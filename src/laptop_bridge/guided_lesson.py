# Path: src/laptop_bridge/guided_lesson.py
"""Opt-in local step tracker for one-session RelayOS visual teaching.

Receives bounded action *metadata* from the authenticated native companion.
Never records keystrokes, input values, clipboard content or window titles.
A verified local event may advance a PRE-AUTHORED step; it cannot prove
that code is correct, a download succeeded or an exercise was completed.
"""
from __future__ import annotations

import secrets
import threading
import time

from . import cursor_guidance, screen_annotations, state
from .config import load_config

_lock = threading.RLock()
_current = None
MAX_SECONDS = 3600
EVENTS_LIMIT = 300
KINDS = frozenset({"app_active", "click", "scroll", "typing", "manual"})
MAX_STEPS = 40


def _permitted():
    if state.emergency_stop() or not load_config().get("capabilities", {}).get("screen_guidance", False):
        raise PermissionError("Screen Guidance must be enabled; Emergency Stop must be off")


def validate_plan(goal, steps, duration_seconds):
    if not isinstance(goal, str) or not 3 <= len(goal.strip()) <= 200:
        raise ValueError("Goal must contain 3..200 characters")
    if isinstance(duration_seconds, bool) or not isinstance(duration_seconds, int) or not 60 <= duration_seconds <= MAX_SECONDS:
        raise ValueError("duration_seconds must be 60..3600")
    if not isinstance(steps, list) or not 1 <= len(steps) <= MAX_STEPS:
        raise ValueError("Plan must include 1..40 steps")
    clean = []
    for step in steps:
        if not isinstance(step, dict) or not isinstance(step.get("instruction"), str) or not 1 <= len(step["instruction"].strip()) <= 400:
            raise ValueError("Each step must include a 1..400 character instruction")
        criterion = step.get("verify", {})
        if not isinstance(criterion, dict) or criterion.get("kind", "manual") not in KINDS:
            raise ValueError("verify.kind must be app_active, click, scroll, typing or manual")
        bundle = criterion.get("bundle_id")
        if bundle is not None and (not isinstance(bundle, str) or not 1 <= len(bundle) <= 150):
            raise ValueError("Invalid optional bundle_id")
        notes = step.get("notes", "")
        if not isinstance(notes, str) or len(notes) > 2000:
            raise ValueError("Notes cannot exceed 2000 characters")
        clean.append({"instruction": step["instruction"].strip(), "verify": {
            "kind": criterion.get("kind", "manual"), "bundle_id": bundle},
            "notes": notes})
    return {"goal": goal.strip(), "steps": clean, "duration_seconds": duration_seconds}


def propose(goal, steps, duration_seconds=1800):
    _permitted()
    plan = validate_plan(goal, steps, duration_seconds)
    token = state.request("guided_lesson", {"target":plan["goal"], "argv":[],
                                             "context": {"plan": plan}})
    return {"request_id":token, "expires_in_seconds":300,
            "message":"Approve Once in the local RelayOS inbox to enable session-only action metadata. No text or passwords are recorded."}


def _visible():
    global _current
    session = _current
    if session is None:
        return {"active":False, "status":"idle"}
    if session["status"] == "active" and (time.time() >= session["expires_at"] or state.emergency_stop()
            or not load_config().get("capabilities", {}).get("screen_guidance", False)):
        session["status"] = "expired"
        _clear_step_ink(session)
        cursor_guidance.clear()
    index = session["step_index"]
    steps = session["plan"]["steps"]
    return {"active":session["status"] == "active", "status":session["status"],
            "session_id":session["id"], "goal":session["plan"]["goal"],
            "step_index":index, "total_steps":len(steps),
            "instruction":steps[index]["instruction"] if index < len(steps) else "Lesson complete",
            "verify": steps[index]["verify"] if index < len(steps) else None,
            "expires_at":session["expires_at"], "last_event_id":session["next_event_id"]-1,
            "notepad_id":session.get("notepad_id")}


def status():
    with _lock:
        return _visible()


def _clear_step_ink(session):
    ids = session.get("step_annotation_ids") or []
    session["step_annotation_ids"] = []
    if ids:
        try:
            screen_annotations.erase(ids=ids)
        except PermissionError:
            pass


def _display_step(session):
    """Default to a discreet direct screen label; never launch the notepad."""
    _clear_step_ink(session)
    step = session["plan"]["steps"][session["step_index"]]
    instruction = step["instruction"]
    suffix = "  •  RelayOS menu → Done when finished" if step["verify"]["kind"] == "manual" else ""
    label = f"STEP {session['step_index'] + 1}/{len(session['plan']['steps'])}: {instruction[:130]}{suffix}"
    remaining = min(900, max(5, int(session["expires_at"] - time.time())))
    response = screen_annotations.draw([{
        "kind": "label", "text": label, "x": .025, "y": .84,
        "w": .57, "font_size": 17, "color": "accent",
    }], duration_seconds=remaining)
    session["step_annotation_ids"] = response["ids"]
    session["notepad_id"] = None
    cursor_guidance.show_tip(instruction[:240], 60)


def activate(request_id):
    approved = state.consume(request_id, expected_kind="guided_lesson")
    plan = approved["details"]["context"]["plan"]
    _permitted()
    global _current
    with _lock:
        if _current is not None and _visible()["active"]:
            raise PermissionError("Stop the existing guided lesson first")
        _current = {
            "id":secrets.token_urlsafe(16), "status":"active", "plan":plan,
            "step_index":0, "expires_at":time.time() + plan["duration_seconds"],
            "events":[], "next_event_id":1, "notepad_id":None,
            "step_annotation_ids":[],
        }
        _display_step(_current)
        return _visible()


def _matches(step, event):
    expect = step["verify"]
    if expect["kind"] == "manual" or event["kind"] != expect["kind"]:
        return False
    return expect["bundle_id"] is None or expect["bundle_id"] == event.get("bundle_id")


def _advance(session):
    session["step_index"] += 1
    if session["step_index"] == len(session["plan"]["steps"]):
        session["status"] = "completed"
        _clear_step_ink(session)
        cursor_guidance.show_tip("Lesson complete. Great work!", 30)
        return
    _display_step(session)


def observe(session_id, kind, bundle_id="", x=None, y=None):
    """Only called by the local control-token authenticated native observer."""
    if kind not in KINDS - {"manual"}:
        raise ValueError("Unsupported activity event")
    if not isinstance(bundle_id, str) or len(bundle_id) > 150:
        raise ValueError("Invalid bundle ID")
    with _lock:
        info = _visible()
        if not info["active"] or not secrets.compare_digest(info["session_id"], session_id):
            raise PermissionError("Lesson not active or token does not match")
        event = {"event_id":_current["next_event_id"], "kind":kind,
                 "bundle_id":bundle_id, "occurred_at":time.time()}
        for key, value in (("x",x),("y",y)):
            if isinstance(value, (int,float)) and not isinstance(value,bool) and 0 <= value <= 1:
                event[key] = round(float(value), 4)
        _current["next_event_id"] += 1
        _current["events"].append(event)
        del _current["events"][:-EVENTS_LIMIT]
        if _matches(_current["plan"]["steps"][_current["step_index"]], event):
            _advance(_current)
        return _visible()


def recent_events(session_id, after_event_id=0, limit=100):
    with _lock:
        info = _visible()
        if info.get("session_id") != session_id:
            raise PermissionError("Unknown lesson")
        if not isinstance(after_event_id, int) or after_event_id < 0 or not isinstance(limit,int) or not 1 <= limit <= 100:
            raise ValueError("Invalid pagination")
        return {"events":[e for e in _current["events"] if e["event_id"] > after_event_id][:limit],
                "status":info}


def local_control(action, session_id):
    if action not in {"pause","resume","stop","confirm"}:
        raise ValueError("Invalid control action")
    with _lock:
        info = _visible()
        if info.get("session_id") != session_id:
            raise PermissionError("Unknown lesson")
        if action == "stop":
            _current["status"] = "stopped"
            _clear_step_ink(_current)
            cursor_guidance.clear()
        elif action == "pause" and _current["status"] == "active":
            _current["status"] = "paused"
            _clear_step_ink(_current)
            cursor_guidance.clear()
        elif action == "resume" and _current["status"] == "paused":
            _permitted()
            _current["status"] = "active"
            _display_step(_current)
        elif action == "confirm" and _current["status"] == "active" and _current["plan"]["steps"][_current["step_index"]]["verify"]["kind"] == "manual":
            _advance(_current)
        return _visible()


def revoke():
    global _current
    with _lock:
        if _current is not None:
            _current["status"] = "stopped"
        if _current is not None:
            _clear_step_ink(_current)
        cursor_guidance.clear()
