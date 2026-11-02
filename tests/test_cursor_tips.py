# Path: tests/test_cursor_tips.py
"""Plain-text bubble lifecycle and association with visual guidance."""
import math
from pathlib import Path
import sys
import tempfile
import time
from unittest import TestCase
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from laptop_bridge import cursor_guidance, state


class CursorTipTests(TestCase):
    def setUp(self):
        permitted = patch.object(cursor_guidance, "_permitted", return_value=True)
        permitted.start()
        self.addCleanup(permitted.stop)
        cursor_guidance.clear()
        self.addCleanup(cursor_guidance.clear)

    def test_standalone_tip_without_point_target(self):
        result = cursor_guidance.show_tip("  Click the profile icon.  ", 30)
        self.assertTrue(result["displaying"])
        status = cursor_guidance.current_target()
        self.assertFalse(status["active"])
        self.assertEqual(status["tip"]["text"], "Click the profile icon.")
        self.assertIsNone(status["tip"]["target_id"])
        self.assertGreater(status["tip"]["expires_at"], time.time())
        self.assertTrue(cursor_guidance.clear_tip()["cleared"])
        self.assertNotIn("tip", cursor_guidance.current_target())

    def test_tip_attached_to_point_and_released_on_arrival(self):
        cursor_guidance.point_to(.25, .75, tip="The app is here.")
        status = cursor_guidance.current_target()
        self.assertEqual(status["tip"]["target_id"], status["id"])
        self.assertEqual(status["tip"]["text"], "The app is here.")
        self.assertTrue(cursor_guidance.complete_target(status["id"])["cleared"])
        self.assertNotIn("tip", cursor_guidance.current_target())

    def test_region_and_path_can_display_typed_tip(self):
        cursor_guidance.highlight_region("rounded_rect", .1, .2, .2, .3, tip="Click here")
        first = cursor_guidance.current_target()
        self.assertEqual(first["tip"]["target_id"], first["id"])
        cursor_guidance.highlight_path([[.1,.1],[.4,.1],[.4,.4]], tip="Outlined item")
        second = cursor_guidance.current_target()
        self.assertNotEqual(first["tip"]["id"], second["tip"]["id"])
        self.assertEqual(second["tip"]["text"], "Outlined item")

    def test_tip_replace_and_clear_does_not_cancel_pointer(self):
        cursor_guidance.point_to(.5, .4, tip="Older message")
        cursor_guidance.show_tip("New response", hold_seconds=12)
        self.assertTrue(cursor_guidance.current_target()["active"])
        self.assertEqual(cursor_guidance.current_target()["tip"]["text"], "New response")
        cursor_guidance.clear_tip()
        self.assertTrue(cursor_guidance.current_target()["active"])

    def test_tip_never_leaks_into_new_point_without_tip(self):
        cursor_guidance.show_tip("Previous answer")
        cursor_guidance.point_to(.2, .4)
        self.assertNotIn("tip", cursor_guidance.current_target())

    def test_timeout_and_capability_revocation(self):
        cursor_guidance.show_tip("Temporary", 1)
        with patch.object(cursor_guidance.time, "time", return_value=time.time() + 2):
            self.assertNotIn("tip", cursor_guidance.current_target())
        cursor_guidance.show_tip("Temporary", 60)
        with patch.object(cursor_guidance, "_permitted", return_value=False):
            self.assertFalse(cursor_guidance.current_target()["active"])
            with self.assertRaises(PermissionError):
                cursor_guidance.show_tip("not permitted")
        self.assertNotIn("tip", cursor_guidance.current_target())

    def test_malformed_or_unbounded_messages_are_rejected_atomically(self):
        cursor_guidance.show_tip("Unchanged")
        bad = ["", "   ", "x" * 241, "👩🏽‍💻" * 240, "a\x00b", "a\nb\nc\nd\ne", 123, None]
        for value in bad:
            with self.subTest(value=str(value)[:20]), self.assertRaises(ValueError):
                cursor_guidance.show_tip(value)
        for d in (0, 61, math.nan, True):
            with self.subTest(duration=d), self.assertRaises(ValueError):
                cursor_guidance.show_tip("Valid", d)
        self.assertEqual(cursor_guidance.current_target()["tip"]["text"], "Unchanged")
        with self.assertRaises(ValueError):
            cursor_guidance.point_to(.2, .4, tip="x" * 300)
        self.assertFalse(cursor_guidance.current_target()["active"])

    def test_emergency_stop_clears_tip(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(state, "STATE_DIR", Path(directory)), \
             patch.object(state, "DATABASE_FILE", Path(directory) / "state.db"):
            state.set_emergency_stop(False)
            cursor_guidance.show_tip("Stop")
            state.set_emergency_stop(True)
            self.assertNotIn("tip", cursor_guidance.current_target())

    def test_mcp_tool_wrappers_exist(self):
        from laptop_bridge import server
        result = server.show_cursor_tip("Answer text")
        self.assertTrue(result["displaying"])
        self.assertEqual(server.clear_cursor_tip(), {"cleared": True})
        self.assertIsNotNone(server.mcp._tool_manager.get_tool("show_cursor_tip"))
        self.assertIsNotNone(server.mcp._tool_manager.get_tool("clear_cursor_tip"))
