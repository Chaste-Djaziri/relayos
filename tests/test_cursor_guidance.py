# Path: tests/test_cursor_guidance.py
"""Visual-only cursor targeting, local status, and arrival acknowledgement."""
import asyncio
import math
from pathlib import Path
import sys
import tempfile
import time
from types import SimpleNamespace
from unittest import TestCase
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from laptop_bridge import cursor_guidance, state


class CursorGuidanceTests(TestCase):
    def setUp(self):
        self.permission = patch.object(cursor_guidance, "_permitted", return_value=True)
        self.permission.start()
        self.addCleanup(self.permission.stop)
        cursor_guidance.clear()
        self.addCleanup(cursor_guidance.clear)

    def test_target_persists_until_arrival_or_expiry(self):
        result = cursor_guidance.point_to(.2, .8, "main", 20)
        self.assertEqual((result["x"], result["y"]), (.2, .8))
        self.assertIn("No mouse input or click", result["message"])
        active = cursor_guidance.current_target()
        self.assertTrue(active["active"])
        self.assertEqual(active["display"], "main")
        self.assertGreater(active["expires_at"], time.time())
        self.assertEqual(cursor_guidance.current_target()["id"], active["id"])
        self.assertEqual(cursor_guidance.complete_target(active["id"]), {"cleared": True})
        self.assertFalse(cursor_guidance.current_target()["active"])

    def test_old_arrival_ack_never_cancels_new_target(self):
        cursor_guidance.point_to(.1, .1)
        old_id = cursor_guidance.current_target()["id"]
        cursor_guidance.point_to(.9, .9)
        new_id = cursor_guidance.current_target()["id"]
        self.assertNotEqual(old_id, new_id)
        self.assertEqual(cursor_guidance.complete_target(old_id), {"cleared": False})
        self.assertEqual(cursor_guidance.current_target()["id"], new_id)
        self.assertTrue(cursor_guidance.complete_target(new_id)["cleared"])

    def test_normalized_values_display_and_duration_are_validated(self):
        for x, y in ((-0.01, .5), (1.01, .1), (math.nan, .2),
                     (math.inf, .1), (.2, -1), (True, 0), ("1", .5)):
            with self.subTest(x=x, y=y), self.assertRaises(ValueError):
                cursor_guidance.point_to(x, y)
        for display in ("window", "1abc", "", "-1", "1234567890123", 42):
            with self.subTest(display=display), self.assertRaises(ValueError):
                cursor_guidance.point_to(.1, .2, display=display)
        for duration in (0, 61, -1, math.nan, True):
            with self.subTest(duration=duration), self.assertRaises(ValueError):
                cursor_guidance.point_to(.5, .5, hold_seconds=duration)
        with self.assertRaises(ValueError):
            cursor_guidance.complete_target(None)
        self.assertFalse(cursor_guidance.current_target()["active"])

    def test_capability_gate_and_expiration_fail_closed(self):
        with patch.object(cursor_guidance, "_permitted", return_value=False):
            with self.assertRaises(PermissionError):
                cursor_guidance.point_to(.5, .5)
        cursor_guidance.point_to(.5, .5, hold_seconds=1)
        with patch.object(cursor_guidance.time, "time", return_value=time.time() + 90):
            self.assertFalse(cursor_guidance.current_target()["active"])
        self.assertFalse(cursor_guidance.current_target()["active"])

    def test_disabled_guidance_revokes_target(self):
        cursor_guidance.point_to(.2, .3)
        with patch.object(cursor_guidance, "_permitted", return_value=False):
            self.assertFalse(cursor_guidance.current_target()["active"])
        self.assertFalse(cursor_guidance.current_target()["active"])

    def test_emergency_stop_clears_active_guidance(self):
        with tempfile.TemporaryDirectory() as path, \
             patch.object(state, "STATE_DIR", Path(path)), \
             patch.object(state, "DATABASE_FILE", Path(path) / "state.sqlite3"):
            state.set_emergency_stop(False)
            cursor_guidance.point_to(.5, .5)
            self.assertTrue(cursor_guidance.current_target()["active"])
            state.set_emergency_stop(True)
            self.assertFalse(cursor_guidance.current_target()["active"])

    def test_local_http_control_requires_token(self):
        from laptop_bridge import control
        async def invoke(path, method="GET", body=None, authorized=False):
            request = SimpleNamespace(
                url=SimpleNamespace(path=path), method=method,
                headers={"x-relayos-control-token": "test"} if authorized else {}
            )
            async def as_json():
                return body or {}
            request.json = as_json
            return await control.handle(request)
        with patch.object(control, "authorized", side_effect=lambda req: bool(req.headers)):
            cursor_guidance.point_to(.7, .4)
            self.assertEqual(asyncio.run(invoke("/control/cursor-guidance")).status_code, 401)
            response = asyncio.run(invoke("/control/cursor-guidance", authorized=True))
            self.assertEqual(response.status_code, 200)
            from json import loads
            target_id = loads(response.body)["id"]
            response = asyncio.run(invoke("/control/cursor-guidance/arrived", "POST", {"id": "old"}, True))
            self.assertFalse(loads(response.body)["cleared"])
            self.assertTrue(cursor_guidance.current_target()["active"])
            response = asyncio.run(invoke("/control/cursor-guidance/arrived", "POST", {"id": target_id}, True))
            self.assertTrue(loads(response.body)["cleared"])
            self.assertFalse(cursor_guidance.current_target()["active"])

