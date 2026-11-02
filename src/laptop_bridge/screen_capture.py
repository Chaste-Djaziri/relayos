# Path: src/laptop_bridge/screen_capture.py
"""Approval-gated, one-frame macOS ScreenCaptureKit bridge.

Image data travels directly from the signed helper's stdout into the MCP
ImageContent response; no screenshot files, recurrent streams or audio.
"""
from __future__ import annotations

import os
import secrets
from pathlib import Path
import subprocess
import sys
import time
import threading

from . import state
from .config import load_config

SCOPES = frozenset({"app", "window", "display"})
MAX_TARGET_BYTES = 256
MAX_IMAGE_BYTES = 4_000_000
MAX_WIDTH = 1600

# An opt-in, time-limited grant for the PRIMARY display only. The grant is
# process-memory-only: a service restart, explicit Stop or Emergency Stop
# immediately removes it. Only the token-protected *local* control route
# may start/extend a session; public MCP tools cannot create consent.
SHARE_MAX_SECONDS = 3600
SHARE_DEFAULT_SECONDS = 1800
_share_lock = threading.Lock()
_share_expires = 0.0
_share_id: str | None = None


def sharing_status() -> dict:
    with _share_lock:
        remaining = max(0, int(_share_expires - time.monotonic() + 0.999))
        session_exists = remaining > 0 and _share_id is not None
    active = session_exists and _enabled() and not state.emergency_stop()
    return {"active": active,
            "expires_in_seconds": remaining if active else 0,
            "scope": "display", "target": "main"}


def set_sharing(enabled: bool, duration_seconds: int = SHARE_DEFAULT_SECONDS) -> dict:
    if not isinstance(enabled, bool):
        raise ValueError("enabled must be a boolean")
    if enabled:
        if not _enabled() or state.emergency_stop():
            raise PermissionError("Screen Guidance must be enabled and Emergency Stop off")
        if (isinstance(duration_seconds, bool) or not isinstance(duration_seconds, int)
                or not 60 <= duration_seconds <= SHARE_MAX_SECONDS):
            raise ValueError("Screen-sharing duration must be 60..3600 seconds")
    global _share_expires, _share_id
    with _share_lock:
        _share_id = secrets.token_urlsafe(24) if enabled else None
        _share_expires = time.monotonic() + duration_seconds if enabled else 0.0
    if not enabled:
        # A user stopping sharing should also invalidate any previously
        # minted short-lived image URLs, not just future capture requests.
        from .screenshot_links import store
        store.revoke_all()
    return sharing_status()


def revoke_sharing() -> None:
    global _share_expires, _share_id
    with _share_lock:
        _share_id = None
        _share_expires = 0.0


def _sharing_id(scope: str, target: str) -> str | None:
    # Never extend consent to a named app/window or external monitor.
    if scope != "display" or target != "main" or not _enabled() or state.emergency_stop():
        return None
    with _share_lock:
        return _share_id if time.monotonic() < _share_expires else None



def _enabled() -> bool:
    return sys.platform == "darwin" and bool(
        load_config().get("capabilities", {}).get("screen_guidance", False)
    )


def normalize(scope: str, target: str) -> tuple[str, str]:
    if scope not in SCOPES:
        raise ValueError("Scope must be app, window, or display")
    if not isinstance(target, str):
        raise ValueError("Target must be a string")
    clean = target.strip()
    if scope == "display" and not clean:
        clean = "main"
    if not clean or len(clean.encode("utf-8")) > MAX_TARGET_BYTES:
        raise ValueError("A specific open app, window title/ID or display ID is required")
    if any(ch in clean for ch in "\r\n\x00"):
        raise ValueError("Target contains invalid characters")
    return scope, clean


def request_capture(scope: str, target: str = "") -> dict:
    if not _enabled():
        raise PermissionError("Enable Screen Guidance in RelayOS first (macOS only)")
    if state.emergency_stop():
        raise PermissionError("Emergency stop is enabled")
    scope, target = normalize(scope, target)
    # A local, visible sharing session authorizes per-request, single-use
    # tokens without posting an approval prompt for each main-display frame.
    # Keep each token scoped/consumable, with full history and no streaming.
    session_id = _sharing_id(scope, target)
    grant = session_id is not None
    token = state.request("screen_capture", {
        "target": f"{scope}:{target}",
        "argv": [],
        "context": {"capture_scope": scope, "capture_target": target,
                    "sharing_session_id": session_id},
    })
    if grant and _sharing_id(scope, target) == session_id:
        state.approve(token)
    else:
        grant = False
    return {
        "request_id": token,
        "scope": scope,
        "target": target,
        "permission": "active_sharing_session" if grant else "local_once",
        "expires_in_seconds": 300,
        "message": (
            "Your locally enabled RelayOS sharing session covers this main-display capture. "
            "Call capture_approved_screen now; no separate approval is needed."
            if grant else
            "Approve Once in RelayOS Approval Inbox, then call capture_approved_screen "
            "with this request ID. No image was captured."
        ),
    }


def helper_path() -> Path:
    # PyInstaller runs the bundled MCP binary next to the signed Swift helper.
    if getattr(sys, "frozen", False):
        candidate = Path(sys.executable).resolve().parent / "RelayOSScreenCapture"
    else:
        # Development only: compile the Swift Package target with swift build.
        project = Path(__file__).resolve().parents[2]
        candidates = [
            project / "Native/LaptopBridgeApp/.build/out/Products/Debug/RelayOSScreenCapture",
            project / "Native/LaptopBridgeApp/.build/arm64-apple-macosx/debug/RelayOSScreenCapture",
            project / "Native/LaptopBridgeApp/.build/debug/RelayOSScreenCapture",
        ]
        candidate = next((path for path in candidates if path.is_file()), candidates[0])
    if not candidate.is_file() or not os.access(candidate, os.X_OK):
        raise RuntimeError("Screen capture helper is not built or packaged with RelayOS")
    return candidate


def capture_after_approval(request_id: str, *, run=subprocess.run) -> tuple[dict, bytes]:
    if not _enabled():
        raise PermissionError("Screen Guidance is disabled or unsupported")
    if not isinstance(request_id, str) or not 12 <= len(request_id) <= 128:
        raise ValueError("Invalid request ID")
    # Fail before consuming user approval if the local helper isn't present.
    executable = helper_path()
    approved = state.consume(request_id, expected_kind="screen_capture")
    if approved["kind"] != "screen_capture":
        raise PermissionError("Approval was not for screen capture")
    context = approved["details"].get("context", {})
    scope, target = normalize(context.get("capture_scope"), context.get("capture_target"))
    # Stop/timeout/restart revokes even a frame that was queued while sharing
    # was active. A new sharing session cannot resurrect old frame approvals.
    if context.get("sharing_session_id") is not None and _sharing_id(scope, target) != context["sharing_session_id"]:
        raise PermissionError("Screen-sharing session ended or expired; frame revoked")
    if approved["details"]["target"] != f"{scope}:{target}":
        raise PermissionError("Capture approval target mismatch")

    started = time.monotonic()
    result = run(
        [str(executable), "--capture", scope, target, str(MAX_WIDTH)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        stdin=subprocess.DEVNULL,
        check=False,
        timeout=25,
    )
    if result.returncode != 0:
        # Only a bounded diagnostic, never return any partial image.
        explanation = result.stderr.decode("utf-8", errors="replace")[-600:].strip()
        raise RuntimeError(explanation or "Screen capture failed")
    # A user may press Stop while ScreenCaptureKit is producing the frame.
    # Never deliver that image after the explicit sharing permission ended.
    if context.get("sharing_session_id") is not None and _sharing_id(scope, target) != context["sharing_session_id"]:
        raise PermissionError("Screen-sharing session ended during capture; frame revoked")
    if state.emergency_stop():
        raise PermissionError("Emergency stop is enabled")
    image = result.stdout
    if not image.startswith(b"\xff\xd8\xff") or not 100 < len(image) <= MAX_IMAGE_BYTES:
        raise RuntimeError("Capture helper returned invalid or oversized JPEG data")
    state.record_result("screen_capture", f"{scope}:{target}",
                        duration_ms=int((time.monotonic() - started) * 1000))
    return {"scope": scope, "target": target, "mime_type": "image/jpeg",
            "bytes": len(image), "captured_once": True}, image
