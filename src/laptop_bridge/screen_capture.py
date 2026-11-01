# Path: src/laptop_bridge/screen_capture.py
"""Approval-gated, one-frame macOS ScreenCaptureKit bridge.

Image data travels directly from the signed helper's stdout into the MCP
ImageContent response; no screenshot files, recurrent streams or audio.
"""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import time

from . import state
from .config import load_config

SCOPES = frozenset({"app", "window", "display"})
MAX_TARGET_BYTES = 256
MAX_IMAGE_BYTES = 4_000_000
MAX_WIDTH = 1600


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
    token = state.request("screen_capture", {
        "target": f"{scope}:{target}",
        "argv": [],
        "context": {"capture_scope": scope, "capture_target": target},
    })
    return {
        "request_id": token,
        "scope": scope,
        "target": target,
        "permission": "local_once",
        "expires_in_seconds": 300,
        "message": "Approve Once in RelayOS Approval Inbox, then call capture_approved_screen with this request ID. No image was captured.",
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
    image = result.stdout
    if not image.startswith(b"\xff\xd8\xff") or not 100 < len(image) <= MAX_IMAGE_BYTES:
        raise RuntimeError("Capture helper returned invalid or oversized JPEG data")
    state.record_result("screen_capture", f"{scope}:{target}",
                        duration_ms=int((time.monotonic() - started) * 1000))
    return {"scope": scope, "target": target, "mime_type": "image/jpeg",
            "bytes": len(image), "captured_once": True}, image
