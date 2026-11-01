# Path: tests/test_screenshot_links.py
"""Regression coverage for temporary approved screenshot HTTPS delivery."""
import asyncio
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
from unittest import TestCase
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from laptop_bridge import screenshot_links, state

JPEG = b"\xff\xd8\xff" + b"j" * 320
ORIGIN = "https://relay.example.ngrok-free.app"


class ScreenshotLinkTests(TestCase):
    def setUp(self):
        self.store = screenshot_links.ScreenshotLinkStore()

    def test_only_bounded_jpeg_and_public_https_origin(self):
        for origin in ("", "http://relay.example", "https://relay.example/path",
                       "https://relay.example?x=1", "https://a@relay.example"):
            with self.subTest(origin=origin), self.assertRaises(ValueError):
                self.store.issue(JPEG, origin)
        with self.assertRaises(ValueError):
            self.store.issue(b"not a jpeg", ORIGIN)
        with self.assertRaises(ValueError):
            self.store.issue(b"\xff\xd8\xff" + b"x" * screenshot_links.MAX_IMAGE_BYTES, ORIGIN)

    def test_reads_are_limited_and_bytes_only_in_memory(self):
        result = self.store.issue(JPEG, ORIGIN)
        token = result["image_url"].split("/")[-1]
        self.assertTrue(result["image_url"].startswith(ORIGIN + "/screenshots/"))
        self.assertEqual(result["image_url_expires_in_seconds"], 120)
        for _ in range(3):
            self.assertEqual(self.store.retrieve(token), JPEG)
        self.assertIsNone(self.store.retrieve(token))
        self.assertIsNone(self.store.retrieve("not-a-valid-token"))
        self.assertNotIn(token, repr(self.store._entries))

    def test_expiration_and_bounded_memory(self):
        with patch.object(screenshot_links.time, "monotonic", return_value=100):
            tokens = [self.store.issue(JPEG, ORIGIN)["image_url"].rsplit("/", 1)[-1] for _ in range(5)]
        self.assertIsNone(self.store.retrieve(tokens[0]))
        with patch.object(screenshot_links.time, "monotonic", return_value=221):
            for token in tokens:
                self.assertIsNone(self.store.retrieve(token))
        self.assertEqual(len(self.store._entries), 0)

    def test_each_link_has_distinct_random_token(self):
        a = self.store.issue(JPEG, ORIGIN)["image_url"]
        b = self.store.issue(JPEG, ORIGIN)["image_url"]
        self.assertNotEqual(a, b)

    def test_emergency_stop_revokes_all_active_links(self):
        with tempfile.TemporaryDirectory() as path, \
             patch.object(state, "STATE_DIR", Path(path)), \
             patch.object(state, "DATABASE_FILE", Path(path) / "state.sqlite3"), \
             patch.object(screenshot_links, "store", self.store):
            state.set_emergency_stop(False)
            token = self.store.issue(JPEG, ORIGIN)["image_url"].rsplit("/", 1)[-1]
            state.set_emergency_stop(True)
            state.set_emergency_stop(False)
            self.assertIsNone(self.store.retrieve(token))

    def test_http_route_is_registered_on_the_actual_mcp_app(self):
        from laptop_bridge import server
        routes = server.mcp.streamable_http_app().routes
        self.assertIn("/screenshots/{token}", {route.path for route in routes})

    def test_http_route_requires_live_capability_and_returns_uncached_jpeg(self):
        from laptop_bridge import server
        with patch.object(screenshot_links, "store", self.store), \
             patch.object(server.state, "emergency_stop", return_value=False), \
             patch.object(server.screen_capture, "_enabled", return_value=True):
            token = self.store.issue(JPEG, ORIGIN)["image_url"].rsplit("/", 1)[-1]
            request = SimpleNamespace(path_params={"token": token})
            response = asyncio.run(server.approved_screenshot_image(request))
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.body, JPEG)
            self.assertEqual(response.media_type, "image/jpeg")
            self.assertIn("no-store", response.headers["cache-control"])
            self.assertEqual(response.headers["referrer-policy"], "no-referrer")
            missing = asyncio.run(server.approved_screenshot_image(request))
            # The link has two remaining permitted downloads, then expires.
            self.assertEqual(missing.status_code, 200)
            self.assertEqual(asyncio.run(server.approved_screenshot_image(request)).status_code, 200)
            self.assertEqual(asyncio.run(server.approved_screenshot_image(request)).status_code, 404)

    def test_http_route_emergency_stop_revokes_token(self):
        from laptop_bridge import server
        with patch.object(screenshot_links, "store", self.store), \
             patch.object(server.state, "emergency_stop", return_value=True):
            token = self.store.issue(JPEG, ORIGIN)["image_url"].rsplit("/", 1)[-1]
            response = asyncio.run(server.approved_screenshot_image(SimpleNamespace(path_params={"token": token})))
            self.assertEqual(response.status_code, 404)
            self.assertIsNone(self.store.retrieve(token))

    def test_mcp_capture_returns_image_url_and_original_image_block(self):
        from laptop_bridge import server
        with patch.object(server.screen_capture, "capture_after_approval", return_value=({"scope": "display", "target": "main"}, JPEG)), \
             patch.object(server, "public_base_url", return_value=ORIGIN), \
             patch.object(server, "load_config", return_value={}), \
             patch.object(server.screenshot_links, "store", self.store):
            metadata, image = server.capture_approved_screen("approved-request")
            self.assertIn("/screenshots/", metadata["image_url"])
            self.assertEqual(image.mime_type, "image/jpeg")
            self.assertEqual(self.store.retrieve(metadata["image_url"].split("/")[-1]), JPEG)

    def test_mcp_does_not_issue_url_without_https_tunnel(self):
        from laptop_bridge import server
        with patch.object(server.screen_capture, "capture_after_approval", return_value=({"scope": "display"}, JPEG)), \
             patch.object(server, "public_base_url", return_value=""), \
             patch.object(server, "load_config", return_value={}):
            metadata, image = server.capture_approved_screen("approved-request")
            self.assertNotIn("image_url", metadata)
            self.assertEqual(image.mime_type, "image/jpeg")
