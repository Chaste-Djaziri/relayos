# Path: tests/test_screen_capture.py
"""Approval-gated one-shot screenshots; stdlib-only test suite."""
from pathlib import Path
import sys
from types import SimpleNamespace
from unittest import TestCase
from unittest.mock import patch
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from laptop_bridge import screen_capture, state


def fake_capture(args, **kwargs):
    assert args[1] == "--capture"
    assert args[-1] == "1600"
    assert kwargs["timeout"] == 25
    return SimpleNamespace(returncode=0, stdout=b"\xff\xd8\xff" + b"x" * 320, stderr=b"")


class ScreenCaptureSecurityTests(TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        for obj, name, value in (
            (state, "STATE_DIR", root),
            (state, "DATABASE_FILE", root / "state.sqlite3"),
            (screen_capture, "_enabled", lambda: True),
            (screen_capture, "helper_path", lambda: root / "RelayOSScreenCapture")
        ):
            item = patch.object(obj, name, value)
            item.start()
            self.addCleanup(item.stop)

    def test_approval_required_once_and_target_bound(self):
        for scope, target in [
            ("app", "com.apple.Safari"),
            ("app", "Firefox"),
            ("window", "My Project"),
            ("window", "1125"),
            ("display", "main"),
            ("display", "1")
        ]:
            with self.subTest(scope=scope, target=target):
                pending = screen_capture.request_capture(scope, target)
                self.assertEqual(pending["permission"], "local_once")
                self.assertEqual(state.approval_inbox()[0]["target"], f"{scope}:{target}")
                with self.assertRaises(PermissionError):
                    screen_capture.capture_after_approval(pending["request_id"], run=fake_capture)
                state.decide_inbox_request(pending["request_id"], "once")
                meta, image = screen_capture.capture_after_approval(
                    pending["request_id"], run=fake_capture)
                self.assertEqual(meta["target"], target)
                self.assertTrue(image.startswith(b"\xff\xd8\xff"))
                with self.assertRaises(PermissionError):
                    screen_capture.capture_after_approval(pending["request_id"], run=fake_capture)

    def test_deny_session_and_always_not_allowed(self):
        token = screen_capture.request_capture("app", "Safari")["request_id"]
        for decision in ("persistent", "session"):
            with self.assertRaisesRegex(ValueError, "Once or Deny"):
                state.decide_inbox_request(token, decision)
        state.decide_inbox_request(token, "deny")
        with self.assertRaises(PermissionError):
            screen_capture.capture_after_approval(token, run=fake_capture)

    def test_other_approval_is_not_consumed(self):
        token = state.request("project_command", {
            "target": "git", "argv": ["git", "status"]
        })
        state.approve(token)
        with self.assertRaisesRegex(PermissionError, "scoped approval"):
            screen_capture.capture_after_approval(token, run=fake_capture)
        self.assertEqual(state.consume(token)["kind"], "project_command")

    def test_denied_when_disabled_or_emergency_stop(self):
        with patch.object(screen_capture, "_enabled", lambda: False):
            with self.assertRaises(PermissionError):
                screen_capture.request_capture("display", "main")
        token = screen_capture.request_capture("window", "Project")["request_id"]
        state.decide_inbox_request(token, "once")
        state.set_emergency_stop(True)
        with self.assertRaises(PermissionError):
            screen_capture.capture_after_approval(token, run=fake_capture)

    def test_invalid_targets_do_not_enter_approval_inbox(self):
        for scope, target in [
            ("file", "anything"), ("window", ""), ("app", "\n"),
            ("window", "x\x00y"), ("app", "x" * 257)
        ]:
            with self.subTest(scope=scope, target=target):
                with self.assertRaises(ValueError):
                    screen_capture.request_capture(scope, target)
        self.assertEqual(state.approval_inbox(), [])


    def test_server_and_screen_capture_tools_are_valid_python(self):
        import ast
        root = Path(__file__).resolve().parents[1]
        for relative in (
            "src/laptop_bridge/server.py",
            "src/laptop_bridge/screen_capture.py",
            "src/laptop_bridge/state.py"
        ):
            with self.subTest(path=relative):
                ast.parse((root / relative).read_text(encoding="utf-8"))

    def test_invalid_image_is_never_returned(self):
        token = screen_capture.request_capture("display", "main")["request_id"]
        state.decide_inbox_request(token, "once")
        def invalid(*args, **kwargs):
            return SimpleNamespace(returncode=0, stdout=b"not-jpeg", stderr=b"")
        with self.assertRaisesRegex(RuntimeError, "invalid or oversized"):
            screen_capture.capture_after_approval(token, run=invalid)
        with self.assertRaises(PermissionError):
            screen_capture.capture_after_approval(token, run=fake_capture)



if __name__ == "__main__":
    import unittest
    unittest.main()
