# Path: tests/test_walkthrough.py
"""Native-observed, fail-closed multi-step walkthroughs (no screenshots)."""
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
from laptop_bridge import control, cursor_guidance, state, walkthrough


class WalkthroughTests(TestCase):
    def setUp(self):
        permitted = patch.object(cursor_guidance, "_permitted", return_value=True)
        permitted.start()
        self.addCleanup(permitted.stop)
        path = tempfile.TemporaryDirectory()
        self.addCleanup(path.cleanup)
        for obj, name, value in [
            (state, "STATE_DIR", Path(path.name)),
            (state, "DATABASE_FILE", Path(path.name) / "state.sqlite3"),
        ]:
            p = patch.object(obj, name, value)
            p.start()
            self.addCleanup(p.stop)
        state.set_emergency_stop(False)
        walkthrough.revoke()
        self.addCleanup(walkthrough.revoke)

    def start(self):
        return walkthrough.start("system_settings_general", duration_seconds=300)

    def test_step_progress_requires_verified_native_observation(self):
        first = self.start()
        self.assertEqual(first["step"], 0)
        self.assertIn("Open System Settings", cursor_guidance.current_target()["tip"]["text"])
        self.assertEqual(walkthrough.observe(first["id"], "com.apple.Safari")["step"], 0)
        self.assertEqual(walkthrough.observe(first["id"], walkthrough.BUNDLE_ID)["step"], 1)
        self.assertEqual(walkthrough.observe(first["id"], walkthrough.BUNDLE_ID, general_selected=True)["step"], 1)
        done = walkthrough.observe(first["id"], walkthrough.BUNDLE_ID,
                                   general_selected=True, accessibility=True)
        self.assertEqual(done["status"], "completed")
        self.assertEqual(done["step"], 2)
        self.assertEqual(walkthrough.status()["active"], False)

    def test_auto_highlight_uses_verified_bound_and_ignores_stale_messages(self):
        first = self.start()
        session = first["id"]
        walkthrough.observe(session, walkthrough.BUNDLE_ID)
        v = walkthrough.observe(session, walkthrough.BUNDLE_ID, accessibility=True,
                                general_bounds=[.1,.2,.12,.035])
        self.assertEqual(v["step"], 1)
        target = cursor_guidance.current_target()
        self.assertTrue(target["active"])
        self.assertEqual(target["region"]["shape"], "rounded_rect")
        self.assertEqual(target["region"]["bounds"], [.1,.2,.12,.035])
        self.assertEqual(target["tip"]["text"], walkthrough.STEPS[1])
        before = target["id"]
        walkthrough.observe(session, walkthrough.BUNDLE_ID, accessibility=True,
                            general_bounds=[.1,.2,.12,.035])
        self.assertEqual(cursor_guidance.current_target()["id"], before)

    def test_switching_apps_clears_stale_highlight_and_restores_instruction(self):
        sid = self.start()["id"]
        walkthrough.observe(sid, walkthrough.BUNDLE_ID, accessibility=True,
                            general_bounds=[.1, .2, .12, .04])
        self.assertTrue(cursor_guidance.current_target()["active"])
        walkthrough.observe(sid, "com.openai.chat")
        current = cursor_guidance.current_target()
        self.assertFalse(current["active"])
        self.assertIn("Return to System Settings", current["tip"]["text"])
        walkthrough.observe(sid, walkthrough.BUNDLE_ID, accessibility=True)
        self.assertEqual(walkthrough.status()["step"], 1)
        self.assertIn("Click General", cursor_guidance.current_target()["tip"]["text"])

    def test_invalid_bounds_do_not_replace_current_instruction(self):
        session = self.start()["id"]
        walkthrough.observe(session, walkthrough.BUNDLE_ID)
        bad = ([.8,.8,.4,.4], [0,0,0,.2], [float("nan"),0,.1,.1], [0,0,.1], [True,0,.1,.1])
        for bounds in bad:
            with self.subTest(bounds=bounds), self.assertRaises(ValueError):
                walkthrough.observe(session, walkthrough.BUNDLE_ID,
                                    accessibility=True, general_bounds=bounds)
        self.assertEqual(walkthrough.status()["step"], 1)

    def test_timeout_nudges_but_never_advances(self):
        first = self.start()
        with patch.object(walkthrough.time, "time", return_value=time.time()+47):
            delayed = walkthrough.status()
            self.assertEqual(delayed["step"], 0)
            self.assertTrue(delayed["attention_needed"])
        with patch.object(walkthrough.time, "time", return_value=time.time()+301):
            expired = walkthrough.status()
            self.assertEqual(expired["status"], "expired")
            self.assertFalse(expired["active"])
            with self.assertRaises(PermissionError):
                walkthrough.observe(first["id"], walkthrough.BUNDLE_ID)

    def test_pause_resume_stop_are_authoritative(self):
        first = self.start()
        sid = first["id"]
        self.assertEqual(walkthrough.control("pause", sid)["status"], "paused")
        self.assertNotIn("tip", cursor_guidance.current_target())
        with self.assertRaises(PermissionError):
            walkthrough.observe(sid, walkthrough.BUNDLE_ID)
        self.assertEqual(walkthrough.control("resume", sid)["status"], "active")
        self.assertEqual(walkthrough.control("stop", sid)["status"], "stopped")
        self.assertEqual(cursor_guidance.current_target()["active"], False)
        with self.assertRaises(PermissionError):
            walkthrough.control("resume", "wrong")
        with self.assertRaises(ValueError):
            walkthrough.control("skip", sid)

    def test_no_unapproved_recipe_or_duration_and_emergency_stop(self):
        with self.assertRaises(ValueError):
            walkthrough.start("arbitrary_project")
        for dur in (0, 59, 901, True, "600"):
            with self.subTest(duration=dur), self.assertRaises(ValueError):
                walkthrough.start(duration_seconds=dur)
        sid = self.start()["id"]
        state.set_emergency_stop(True)
        self.assertEqual(walkthrough.status()["status"], "stopped")
        with self.assertRaises(PermissionError):
            walkthrough.observe(sid, walkthrough.BUNDLE_ID)
        with self.assertRaises(PermissionError):
            self.start()

    def test_local_http_control_authorization(self):
        session_id = self.start()["id"]
        async def call(method, path, payload=None, authorized=False):
            request = SimpleNamespace(url=SimpleNamespace(path=path), method=method,
                                      headers={"x-relayos-control-token": "a"} if authorized else {})
            async def read(): return payload or {}
            request.json = read
            return await control.handle(request)
        with patch.object(control, "authorized", side_effect=lambda r: bool(r.headers)):
            self.assertEqual(asyncio.run(call("GET", "/control/walkthrough")).status_code, 401)
            result = asyncio.run(call("GET", "/control/walkthrough", authorized=True))
            self.assertEqual(json.loads(result.body)["step"], 0)
            result = asyncio.run(call("POST", "/control/walkthrough/observe", {
                "id": session_id, "frontmost_bundle_id": walkthrough.BUNDLE_ID
            }, True))
            self.assertEqual(json.loads(result.body)["step"], 1)
            result = asyncio.run(call("POST", "/control/walkthrough/control", {
                "id": session_id, "action": "stop"
            }, True))
            self.assertEqual(json.loads(result.body)["status"], "stopped")
            self.assertEqual(asyncio.run(call("POST", "/control/walkthrough/observe", {
                "id": session_id, "frontmost_bundle_id": walkthrough.BUNDLE_ID
            }, True)).status_code, 403)

    def test_public_mcp_tools_start_status_stop_only(self):
        from laptop_bridge import server
        started = server.start_guided_walkthrough(duration_seconds=60)
        self.assertEqual(server.guided_walkthrough_status()["id"], started["id"])
        self.assertEqual(server.stop_guided_walkthrough()["status"], "stopped")
        self.assertIsNotNone(server.mcp._tool_manager.get_tool("start_guided_walkthrough"))
        self.assertIsNotNone(server.mcp._tool_manager.get_tool("guided_walkthrough_status"))
        self.assertIsNotNone(server.mcp._tool_manager.get_tool("stop_guided_walkthrough"))
