# Path: tests/test_guidance_workspace.py
"""Bounded notepad, approved lesson and metadata-only action progression."""
import asyncio
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
from unittest import TestCase
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from laptop_bridge import cursor_guidance, guided_lesson, guidance_workspace, screen_annotations, state


class GuidanceWorkspaceTests(TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        for obj, attribute, value in [
            (state, "STATE_DIR", Path(directory.name)),
            (state, "DATABASE_FILE", Path(directory.name) / "workspace.sqlite3"),
            (guidance_workspace, "_require_permission", lambda: None),
            (guided_lesson, "_permitted", lambda: None),
            (guidance_workspace, "load_config", lambda: {"capabilities": {"screen_guidance": True}}),
            (guided_lesson, "load_config", lambda: {"capabilities": {"screen_guidance": True}}),
            (cursor_guidance, "_permitted", lambda: True),
        ]:
            p = patch.object(obj, attribute, value)
            p.start()
            self.addCleanup(p.stop)
        state.set_emergency_stop(False)
        guided_lesson.revoke()
        guidance_workspace.revoke()
        self.addCleanup(guided_lesson.revoke)
        self.addCleanup(guidance_workspace.revoke)

    def test_notepad_has_independent_drawing_ids_and_local_visibility(self):
        board = guidance_workspace.open_board("Lesson canvas", 600)
        result = guidance_workspace.add_elements(board["id"], [
            {"kind": "text", "x": .1, "y": .1, "w": .6, "text": "x = 1"},
            {"kind": "ellipse", "x": .2, "y": .3, "w": .3, "h": .1, "color": "green"},
            {"kind": "path", "points": [[.1,.1],[.3,.2],[.4,.4]]},
        ])
        self.assertEqual(result["total_elements"], 3)
        self.assertEqual(len(set(result["added_ids"])), 3)
        self.assertFalse(guidance_workspace.local_action("hide")["visible"])
        self.assertTrue(guidance_workspace.edit_board(board["id"], "show")["visible"])
        self.assertEqual(guidance_workspace.edit_board(
            board["id"], "remove", [result["added_ids"][1]])["total_elements"], 2)
        self.assertEqual(guidance_workspace.edit_board(
            board["id"], "clear")["total_elements"], 0)
        guidance_workspace.edit_board(board["id"], "close")
        self.assertFalse(guidance_workspace.current()["active"])
        with self.assertRaises(PermissionError):
            guidance_workspace.add_elements(board["id"], [{"kind":"text","text":"stale"}])

    def test_invalid_drawings_are_rejected_atomically(self):
        board = guidance_workspace.open_board()
        invalid = [
            {"kind":"text","text":"", "x":.1, "y":.2},
            {"kind":"code","text":"bad","w":.3, "x":.9},
            {"kind":"rect","x":.9,"w":.3,"h":.1},
            {"kind":"ellipse","x":0,"y":0,"w":.1,"h":.1,"color":"<script>"},
            {"kind":"path","points":[[.3,.1]]},
            {"kind":"text","text":"hello","x":float("nan")},
        ]
        for item in invalid:
            with self.subTest(item=item), self.assertRaises(ValueError):
                guidance_workspace.add_elements(board["id"], [item])
        self.assertEqual(guidance_workspace.current()["elements"], [])
        with self.assertRaises(ValueError):
            guidance_workspace.add_elements(board["id"], [
                {"kind":"text","text":"Valid"},
                {"kind":"rect","w":10,"h":.2},
            ])
        self.assertEqual(guidance_workspace.current()["elements"], [])

    def test_approved_lesson_advances_on_declared_metadata_only(self):
        steps = [
            {"instruction":"Open VS Code", "verify":{"kind":"app_active","bundle_id":"com.microsoft.VSCode"}},
            {"instruction":"Scroll in VS Code", "verify":{"kind":"scroll","bundle_id":"com.microsoft.VSCode"},
             "notes":"Look for the Explorer sidebar."},
            {"instruction":"Complete the exercise", "verify":{"kind":"manual"}},
        ]
        proposed = guided_lesson.propose("Learn Python foundations", steps, 600)
        with self.assertRaises(PermissionError):
            guided_lesson.activate(proposed["request_id"])
        state.approve(proposed["request_id"])
        info = guided_lesson.activate(proposed["request_id"])
        self.assertTrue(info["active"])
        sid = info["session_id"]
        self.assertEqual(info["step_index"], 0)
        self.assertEqual(guided_lesson.observe(sid, "app_active", "com.apple.finder")["step_index"], 0)
        self.assertEqual(guided_lesson.observe(sid, "app_active", "com.microsoft.VSCode")["step_index"], 1)
        self.assertEqual(guided_lesson.observe(sid, "typing", "com.microsoft.VSCode")["step_index"], 1)
        self.assertEqual(guided_lesson.observe(sid, "scroll", "com.microsoft.VSCode")["step_index"], 2)
        self.assertEqual(guided_lesson.observe(sid, "click", "com.microsoft.VSCode")["step_index"], 2)
        events = guided_lesson.recent_events(sid)["events"]
        self.assertEqual(len(events), 5)
        self.assertTrue(all("text" not in item and "key" not in item for item in events))
        self.assertEqual(guided_lesson.local_control("confirm", sid)["status"], "completed")
        self.assertFalse(guided_lesson.status()["active"])
        self.assertFalse(guided_lesson.local_control("stop", sid)["active"])

    def test_pausing_stops_observation_and_emergency_stop_revokes(self):
        request = guided_lesson.propose("Learn Python", [
            {"instruction":"Open the editor","verify":{"kind":"app_active"}}
        ])
        state.approve(request["request_id"])
        sid = guided_lesson.activate(request["request_id"])["session_id"]
        self.assertEqual(guided_lesson.local_control("pause", sid)["status"], "paused")
        with self.assertRaises(PermissionError):
            guided_lesson.observe(sid, "click")
        self.assertEqual(guided_lesson.local_control("resume", sid)["status"], "active")
        state.set_emergency_stop(True)
        self.assertFalse(guided_lesson.status()["active"])
        self.assertFalse(guidance_workspace.current()["active"])
        with self.assertRaises(PermissionError):
            guided_lesson.observe(sid, "click")

    def test_local_control_requires_authenticated_loopback_token(self):
        try:
            from laptop_bridge import control
        except ModuleNotFoundError:
            self.skipTest("HTTP integration dependencies are not installed in this Python environment")
        board = guidance_workspace.open_board()
        async def call(method, path, payload=None, authorized=False):
            req = SimpleNamespace(url=SimpleNamespace(path=path), method=method,
                                  headers={"x-relayos-control-token":"a"} if authorized else {})
            async def body(): return payload or {}
            req.json = body
            return await control.handle(req)
        with patch.object(control, "authorized", side_effect=lambda req: bool(req.headers)):
            forbidden = asyncio.run(call("GET", "/control/guidance-notepad"))
            self.assertEqual(forbidden.status_code, 401)
            found = asyncio.run(call("GET", "/control/guidance-notepad", authorized=True))
            self.assertEqual(json.loads(found.body)["id"], board["id"])
            hidden = asyncio.run(call("POST", "/control/guidance-notepad/action",
                                      {"action":"hide"}, True))
            self.assertFalse(json.loads(hidden.body)["visible"])

    def test_guided_lesson_uses_screen_overlay_without_opening_notepad(self):
        external = screen_annotations.draw([
            {"kind":"ellipse","x":.2,"y":.3,"w":.1,"h":.15}
        ])["ids"][0]
        proposed = guided_lesson.propose("Explain code on my screen", [
            {"instruction":"Open the editor","verify":{"kind":"app_active"}},
            {"instruction":"Review the expression","verify":{"kind":"manual"}},
        ])
        state.approve(proposed["request_id"])
        sid = guided_lesson.activate(proposed["request_id"])["session_id"]
        self.assertFalse(guidance_workspace.current()["active"])
        original_ids = [x["id"] for x in screen_annotations.current()["annotations"]]
        self.assertEqual(len(original_ids), 2)
        self.assertIn(external, original_ids)
        guided_lesson.observe(sid, "app_active", "com.apple.finder")
        self.assertEqual(len(screen_annotations.current()["annotations"]), 2)
        self.assertNotIn(original_ids[1], [x["id"] for x in screen_annotations.current()["annotations"]])
        guided_lesson.local_control("stop", sid)
        self.assertEqual([x["id"] for x in screen_annotations.current()["annotations"]], [external])
