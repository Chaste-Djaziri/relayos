# Path: tests/test_screen_highlights.py
"""Screen highlight input validation, local control and lifecycle."""
import asyncio
import json
from pathlib import Path
import sys
from types import SimpleNamespace
from unittest import TestCase
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from laptop_bridge import cursor_guidance


class HighlightTests(TestCase):
    def setUp(self):
        permission = patch.object(cursor_guidance, "_permitted", return_value=True)
        permission.start()
        self.addCleanup(permission.stop)
        cursor_guidance.clear()
        self.addCleanup(cursor_guidance.clear)

    def test_rounded_rectangle_geometry_and_shared_target(self):
        result = cursor_guidance.highlight_region("rounded_rect", .1, .2, .3, .1)
        self.assertTrue(result["highlighting"])
        current = cursor_guidance.current_target()
        self.assertTrue(current["active"])
        self.assertEqual(current["region"]["shape"], "rounded_rect")
        self.assertEqual(current["region"]["bounds"], [.1, .2, .3, .1])
        self.assertAlmostEqual(current["x"], .25)
        self.assertAlmostEqual(current["y"], .25)
        self.assertTrue(current["region"]["closed"])
        self.assertEqual(current["proximity_radius"], 48)
        self.assertTrue(current["show_cursor"])
        self.assertNotIn("image", json.dumps(current))

    def test_rectangle_ellipse_without_cursor_and_configurable_visuals(self):
        for shape in ("rect", "ellipse"):
            with self.subTest(shape=shape):
                cursor_guidance.highlight_region(
                    shape, 0, 0, .15, .25, display="3452",
                    hold_seconds=50, proximity_radius=24,
                    show_cursor=False, fill_opacity=.2, stroke_width=5)
                active = cursor_guidance.current_target()
                self.assertFalse(active["show_cursor"])
                self.assertEqual(active["region"]["stroke_width"], 5)
                self.assertEqual(active["region"]["fill_opacity"], .2)
                self.assertEqual(active["display"], "3452")

    def test_polygon_and_freeform_path(self):
        vertices = [[.1, .1], [.9, .2], [.8, .5], [.2, .6]]
        cursor_guidance.highlight_path(vertices, "polygon")
        a = cursor_guidance.current_target()
        self.assertEqual(a["region"]["points"], vertices)
        self.assertTrue(a["region"]["closed"])
        self.assertAlmostEqual(a["x"], .5)
        self.assertAlmostEqual(a["y"], .35)
        cursor_guidance.highlight_path([[0,0], [.2,.4], [.6,.6]], shape="path", closed=False)
        b = cursor_guidance.current_target()
        self.assertNotEqual(a["id"], b["id"])
        self.assertFalse(b["region"]["closed"])
        self.assertEqual(b["region"]["fill_opacity"], 0)

    def test_reject_invalid_regions_without_publishing(self):
        args = [
            ("bad", .1, .1, .2, .2),
            ("rect", -.1, .1, .2, .2),
            ("rect", .9, .1, .2, .2),
            ("ellipse", .1, .9, .2, .2),
            ("rect", .1, .1, 0, .2),
            ("rounded_rect", .1, .1, .2, float("nan")),
        ]
        for values in args:
            with self.subTest(values=values), self.assertRaises(ValueError):
                cursor_guidance.highlight_region(*values)
        with self.assertRaises(ValueError):
            cursor_guidance.highlight_region("rect", .1, .1, .2, .2, fill_opacity=.9)
        with self.assertRaises(ValueError):
            cursor_guidance.highlight_region("rect", .1, .1, .2, .2, stroke_width=0)
        with self.assertRaises(ValueError):
            cursor_guidance.highlight_region("rect", .1, .1, .2, .2, proximity_radius=201)
        with self.assertRaises(ValueError):
            cursor_guidance.highlight_region("rect", .1, .1, .2, .2, show_cursor=1)
        self.assertFalse(cursor_guidance.current_target()["active"])

    def test_invalid_paths_rejected_and_bounded(self):
        samples = [
            ([[0,0],[.5,.5]], "polygon"),
            ([[0,0]], "path"),
            ([[0,0],[2,1]], "path"),
            ([[0,0],[float("inf"),1]], "path"),
            ([[0,0],[0,0]], "path"),
            ([[0,0],[1,0],[1,1]], "polygon", False),
            ([[0,0]] * 97, "path"),
            ([[0,0], [1]], "path"),
        ]
        for sample in samples:
            with self.subTest(sample=str(sample)[:90]), self.assertRaises(ValueError):
                cursor_guidance.highlight_path(*sample)
        self.assertFalse(cursor_guidance.current_target()["active"])

    def test_highlight_replaces_point_and_clears_on_proximity_ack(self):
        cursor_guidance.point_to(.2, .2)
        old_id = cursor_guidance.current_target()["id"]
        cursor_guidance.highlight_region("rect", .6, .6, .2, .2)
        new_id = cursor_guidance.current_target()["id"]
        self.assertFalse(cursor_guidance.complete_target(old_id)["cleared"])
        self.assertTrue(cursor_guidance.current_target()["active"])
        self.assertTrue(cursor_guidance.complete_target(new_id)["cleared"])
        self.assertFalse(cursor_guidance.current_target()["active"])

    def test_emergency_stop_and_disabled_capability_fail_closed(self):
        with patch.object(cursor_guidance, "_permitted", return_value=False):
            with self.assertRaises(PermissionError):
                cursor_guidance.highlight_region("rect", .1, .1, .2, .2)
            with self.assertRaises(PermissionError):
                cursor_guidance.highlight_path([[0,0],[1,1]], "path")
        self.assertFalse(cursor_guidance.current_target()["active"])

    def test_mcp_tool_wrappers_and_registration(self):
        from laptop_bridge import server
        a = server.highlight_screen_region("ellipse", .2, .3, .2, .2)
        self.assertTrue(a["highlighting"])
        b = server.highlight_screen_path([[0,0],[1,0],[1,1]], "polygon")
        self.assertTrue(b["highlighting"])
        self.assertEqual(server.clear_screen_highlight(), {"cleared": True})
        for name in ("highlight_screen_region", "highlight_screen_path", "clear_screen_highlight"):
            self.assertIsNotNone(server.mcp._tool_manager.get_tool(name))

    def test_control_endpoint_returns_shape_only_when_authenticated(self):
        from laptop_bridge import control
        cursor_guidance.highlight_region("rect", .1, .2, .1, .2)
        request = SimpleNamespace(
            url=SimpleNamespace(path="/control/cursor-guidance"),
            method="GET", headers={})
        with patch.object(control, "authorized", return_value=False):
            response = asyncio.run(control.handle(request))
            self.assertEqual(response.status_code, 401)
        with patch.object(control, "authorized", return_value=True):
            response = asyncio.run(control.handle(request))
            self.assertEqual(response.status_code, 200)
            self.assertEqual(json.loads(response.body)["region"]["shape"], "rect")
