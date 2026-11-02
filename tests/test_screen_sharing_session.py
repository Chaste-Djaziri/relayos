# Path: tests/test_screen_sharing_session.py
"""Locally initiated, memory-only main-display sharing is bounded and revocable."""
import asyncio
import json
from pathlib import Path
import sys
import tempfile
import time
from types import SimpleNamespace
from unittest import TestCase
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from laptop_bridge import control, screen_capture, state


def fake_jpeg(argv, **kwargs):
    assert argv[1:4] == ["--capture", "display", "main"]
    return SimpleNamespace(returncode=0, stdout=b"\xff\xd8\xff" + b"z" * 300, stderr=b"")


class ScreenSharingSessionTests(TestCase):
    def setUp(self):
        root = tempfile.TemporaryDirectory()
        self.addCleanup(root.cleanup)
        patches = [
            patch.object(state, "STATE_DIR", Path(root.name)),
            patch.object(state, "DATABASE_FILE", Path(root.name) / "test.db"),
            patch.object(screen_capture, "_enabled", return_value=True),
            patch.object(screen_capture, "helper_path", return_value=Path(root.name) / "capture"),
        ]
        for item in patches:
            item.start()
            self.addCleanup(item.stop)
        screen_capture.revoke_sharing()
        self.addCleanup(screen_capture.revoke_sharing)

    def test_default_remains_approve_once(self):
        self.assertFalse(screen_capture.sharing_status()["active"])
        request = screen_capture.request_capture("display", "")
        self.assertEqual(request["permission"], "local_once")
        self.assertEqual(len(state.pending_requests()), 1)
        with self.assertRaises(PermissionError):
            screen_capture.capture_after_approval(request["request_id"], run=fake_jpeg)

    def test_one_local_opt_in_covers_multiple_one_shot_main_display_frames(self):
        status = screen_capture.set_sharing(True, 1800)
        self.assertTrue(status["active"])
        self.assertGreater(status["expires_in_seconds"], 1700)
        for _ in range(3):
            request = screen_capture.request_capture("display", "")
            self.assertEqual(request["permission"], "active_sharing_session")
            self.assertEqual(state.pending_requests(), [])
            metadata, data = screen_capture.capture_after_approval(request["request_id"], run=fake_jpeg)
            self.assertEqual(metadata["scope"], "display")
            self.assertTrue(data.startswith(b"\xff\xd8\xff"))
            with self.assertRaises(PermissionError):
                screen_capture.capture_after_approval(request["request_id"], run=fake_jpeg)

    def test_named_apps_windows_and_external_displays_still_require_once(self):
        screen_capture.set_sharing(True)
        for scope, target in [("app", "Safari"), ("window", "123"), ("display", "441")]:
            with self.subTest(scope=scope, target=target):
                req = screen_capture.request_capture(scope, target)
                self.assertEqual(req["permission"], "local_once")
                self.assertTrue(any(x["request_id"] == req["request_id"] for x in state.pending_requests()))

    def test_stop_cancels_preapproved_frames_even_before_consumption(self):
        screen_capture.set_sharing(True)
        frame = screen_capture.request_capture("display", "main")
        self.assertEqual(frame["permission"], "active_sharing_session")
        screen_capture.set_sharing(False)
        self.assertFalse(screen_capture.sharing_status()["active"])
        with self.assertRaisesRegex(PermissionError, "revoked"):
            screen_capture.capture_after_approval(frame["request_id"], run=fake_jpeg)

    def test_stop_during_capture_prevents_image_delivery(self):
        screen_capture.set_sharing(True)
        req = screen_capture.request_capture("display", "main")
        def capture_and_stop(argv, **kwargs):
            screen_capture.set_sharing(False)
            return fake_jpeg(argv, **kwargs)
        with self.assertRaisesRegex(PermissionError, "during capture"):
            screen_capture.capture_after_approval(req["request_id"], run=capture_and_stop)

    def test_stop_revokes_temporary_screenshot_urls(self):
        from laptop_bridge.screenshot_links import store
        screen_capture.set_sharing(True)
        issued = store.issue(bytes([255, 216, 255]) + b"a" * 300,
                             "https://example.ngrok-free.app")
        token = issued["image_url"].rsplit("/", 1)[-1]
        screen_capture.set_sharing(False)
        self.assertIsNone(store.retrieve(token))

    def test_new_session_cannot_resurrect_old_frames(self):
        screen_capture.set_sharing(True)
        request = screen_capture.request_capture("display", "main")
        screen_capture.set_sharing(False)
        screen_capture.set_sharing(True)
        with self.assertRaisesRegex(PermissionError, "revoked"):
            screen_capture.capture_after_approval(request["request_id"], run=fake_jpeg)
        next_request = screen_capture.request_capture("display", "main")
        self.assertEqual(next_request["permission"], "active_sharing_session")

    def test_expiration_blocks_capture(self):
        with patch.object(screen_capture.time, "monotonic", return_value=100.0):
            screen_capture.set_sharing(True, 60)
            req = screen_capture.request_capture("display", "main")
        with patch.object(screen_capture.time, "monotonic", return_value=165.0):
            self.assertFalse(screen_capture.sharing_status()["active"])
            with self.assertRaisesRegex(PermissionError, "revoked"):
                screen_capture.capture_after_approval(req["request_id"], run=fake_jpeg)

    def test_emergency_stop_revokes_session(self):
        state.set_emergency_stop(False)
        screen_capture.set_sharing(True)
        req = screen_capture.request_capture("display", "main")
        state.set_emergency_stop(True)
        self.assertFalse(screen_capture.sharing_status()["active"])
        with self.assertRaises(PermissionError):
            screen_capture.capture_after_approval(req["request_id"], run=fake_jpeg)
        state.set_emergency_stop(False)
        self.assertFalse(screen_capture.sharing_status()["active"])

    def test_reject_invalid_duration_or_activation(self):
        for length in (0, 59, 3601, True, 10.5):
            with self.subTest(length=length), self.assertRaises(ValueError):
                screen_capture.set_sharing(True, length)
        with self.assertRaises(ValueError):
            screen_capture.set_sharing("true")
        with patch.object(screen_capture, "_enabled", return_value=False):
            with self.assertRaises(PermissionError):
                screen_capture.set_sharing(True)

    def test_only_token_authenticated_local_control_can_enable(self):
        async def call(method, authenticated, payload=None):
            request = SimpleNamespace(
                method=method,
                url=SimpleNamespace(path="/control/screen-sharing"),
                headers={"x-relayos-control-token":"a"} if authenticated else {},
            )
            async def read():
                return payload
            request.json = read
            return await control.handle(request)
        with patch.object(control, "authorized", side_effect=lambda r: bool(r.headers)):
            self.assertEqual(asyncio.run(call("POST", False, {"enabled":True})).status_code, 401)
            self.assertFalse(screen_capture.sharing_status()["active"])
            self.assertEqual(asyncio.run(call("POST", True, {"enabled":True,"duration_seconds":1800})).status_code, 200)
            self.assertTrue(json.loads(asyncio.run(call("GET", True)).body)["active"])
            self.assertEqual(asyncio.run(call("POST", True, {"enabled":True,"duration_seconds":0})).status_code, 400)
            self.assertEqual(asyncio.run(call("POST", True, {"enabled":False})).status_code, 200)
            self.assertFalse(screen_capture.sharing_status()["active"])
