# Path: tests/test_screen_annotations.py
"""Direct display overlay annotations: validation, lifecycle and MCP gates."""
import asyncio
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
from unittest import TestCase
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from laptop_bridge import cursor_guidance, screen_annotations, state


class ScreenAnnotationTests(TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        for obj, attr, value in [
            (state, "STATE_DIR", Path(directory.name)),
            (state, "DATABASE_FILE", Path(directory.name) / "test.sqlite3"),
            (cursor_guidance, "_permitted", lambda: True),
        ]:
            patcher = patch.object(obj, attr, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        state.set_emergency_stop(False)
        screen_annotations.erase_all()
        self.addCleanup(screen_annotations.erase_all)

    def test_direct_screen_labels_arrows_circles_and_scribbles(self):
        items = [
            {"kind":"label","x":.05,"y":.12,"w":.20,"text":"Left front wheel", "color":"yellow"},
            {"kind":"arrow","x":.25,"y":.20,"w":.18,"h":.40,"color":"red"},
            {"kind":"ellipse","x":.32,"y":.55,"w":.20,"h":.23,"color":"green"},
            {"kind":"scribble","x":0,"y":0,"points":[[.1,.1],[.2,.14],[.3,.1]],"color":"blue"},
        ]
        value = screen_annotations.draw(items, duration_seconds=120)
        self.assertEqual(value["count"], 4)
        self.assertEqual(len(set(value["ids"])), 4)
        self.assertEqual(screen_annotations.current()["annotations"][1]["w"], .18)
        self.assertEqual(screen_annotations.erase(ids=value["ids"][:2])["remaining"], 2)
        self.assertEqual(screen_annotations.erase(display="main")["removed"], 2)
        self.assertFalse(screen_annotations.current()["active"])

    def test_replace_is_display_scoped_and_stale_ids_are_inert(self):
        first = screen_annotations.draw([{"kind":"text","text":"Car","x":.1,"y":.1}])
        second = screen_annotations.draw([{"kind":"rect","x":.1,"y":.1,"w":.2,"h":.2}], display="42")
        screen_annotations.draw([{"kind":"label","text":"Wheel","x":.2,"y":.2}], replace=True)
        snapshot = screen_annotations.current()["annotations"]
        self.assertEqual(len(snapshot), 2)
        self.assertNotIn(first["ids"][0], [s["id"] for s in snapshot])
        self.assertIn(second["ids"][0], [s["id"] for s in snapshot])
        self.assertEqual(screen_annotations.erase(ids=first["ids"])["removed"], 0)

    def test_invalid_annotations_do_not_replace_existing_drawings(self):
        original = screen_annotations.draw([{"kind":"text","x":.1,"y":.1,"text":"Safe"}])
        invalid = [
            {"kind":"label","x":.9,"y":.1,"w":.2,"text":"Offscreen"},
            {"kind":"ellipse","x":.8,"y":.5,"w":.3,"h":.2},
            {"kind":"arrow","x":.1,"y":.2,"w":-.2,"h":.1},
            {"kind":"path","points":[[.1,.1]]},
            {"kind":"text","x":float("nan"),"y":.1,"text":"No"},
            {"kind":"code","x":.2,"y":.2,"text":"\x00"},
            {"kind":"scribble","points":[[.1,.1],[True,.2]]},
        ]
        for item in invalid:
            with self.subTest(kind=item.get("kind")), self.assertRaises(ValueError):
                screen_annotations.draw([item], replace=True)
        self.assertEqual(screen_annotations.current()["annotations"][0]["id"], original["ids"][0])
        self.assertEqual(len(screen_annotations.current()["annotations"]), 1)

    def test_expiry_and_permission_revocation(self):
        first = screen_annotations.draw([{"kind":"text","x":.1,"y":.1,"text":"Expires"}], duration_seconds=5)
        import time
        with patch.object(screen_annotations.time, "time", return_value=time.time() + 8):
            self.assertFalse(screen_annotations.current()["active"])
        self.assertEqual(screen_annotations.erase(ids=first["ids"])["removed"], 0)
        screen_annotations.draw([{"kind":"label","x":.1,"y":.1,"text":"Hidden"}])
        with patch.object(cursor_guidance, "_permitted", return_value=False):
            self.assertFalse(screen_annotations.current()["active"])
            with self.assertRaises(PermissionError):
                screen_annotations.draw([{"kind":"text","text":"No","x":.1,"y":.1}])

    def test_unauthenticated_control_is_rejected_and_mcp_tools_exist(self):
        from laptop_bridge import control, server
        async def request(path, auth=False):
            req = SimpleNamespace(method="GET", url=SimpleNamespace(path=path),
                                  headers={"x-relayos-control-token":"x"} if auth else {})
            return await control.handle(req)
        with patch.object(control, "authorized", side_effect=lambda request: bool(request.headers)):
            self.assertEqual(asyncio.run(request("/control/screen-annotations")).status_code, 401)
            body = asyncio.run(request("/control/screen-annotations", True))
            self.assertEqual(json.loads(body.body)["annotations"], [])
        for name in ("draw_screen_annotations", "screen_annotation_status",
                     "erase_screen_annotations", "clear_all_screen_annotations"):
            self.assertIsNotNone(server.mcp._tool_manager.get_tool(name))
