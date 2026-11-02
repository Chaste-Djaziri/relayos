# Path: tests/test_storage_audit.py
"""Read-only storage inspection and local approval regression tests."""
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from laptop_bridge import state, storage_audit
try:
    from laptop_bridge import server
except ModuleNotFoundError:
    server = None  # MCP/psutil are unavailable in a minimal local Python env.


class StorageAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state_dir = self.root / "state"
        self.state_dir.mkdir()
        self.state_patches = [
            patch.object(state, "STATE_DIR", self.state_dir),
            patch.object(state, "DATABASE_FILE", self.state_dir / "state.sqlite3"),
        ]
        for item in self.state_patches:
            item.start()
            self.addCleanup(item.stop)

    def test_disk_overview_does_not_enumerate_files(self):
        values = SimpleNamespace(total=1000, used=400, free=600)
        with patch.object(storage_audit.shutil, "disk_usage", return_value=values):
            result = storage_audit.disk_overview()
        self.assertEqual(result["used_percent"], 40.0)
        self.assertEqual(result["free_bytes"], 600)

    def test_allowed_root_is_explicit_and_not_filesystem_root(self):
        home = self.root / "me"
        folder = home / "Projects"
        folder.mkdir(parents=True)
        with patch.object(storage_audit.Path, "home", return_value=home):
            self.assertEqual(storage_audit.permitted_scan_root(str(folder)), folder.resolve())
            with self.assertRaises(PermissionError):
                storage_audit.permitted_scan_root(str(self.root))
            with self.assertRaises(PermissionError):
                storage_audit.permitted_scan_root("/")

    def test_detects_caches_and_redacts_secret_filenames(self):
        path = self.root / "project"
        (path / "node_modules").mkdir(parents=True)
        (path / "node_modules" / "lib.js").write_bytes(b"x" * 200)
        (path / ".env").write_bytes(b"secret" * 1000)
        (path / "id_ed25519").write_bytes(b"private" * 3000)
        report = storage_audit.scan_folder(path)
        self.assertEqual(report["credential_filename_markers"],
                         {"environment file": 1, "credential or key filename": 1})
        self.assertTrue(any(x["category"] == "reinstallable dependencies"
                            for x in report["cache_candidates"]))
        self.assertTrue(all(".env" not in x["relative_path"] and
                            "id_ed25519" not in x["relative_path"]
                            for x in report["largest_files"]))
        self.assertTrue((path / ".env").exists())

    def test_does_not_follow_outside_symlinks(self):
        safe = self.root / "safe"
        outside = self.root / "outside"
        safe.mkdir()
        outside.mkdir()
        (outside / "big.bin").write_bytes(b"x" * 9000)
        (safe / "linked").symlink_to(outside, target_is_directory=True)
        report = storage_audit.scan_folder(safe)
        self.assertEqual(report["symlinks_skipped"], 1)
        self.assertEqual(report["logical_bytes_scanned"], 0)

    def test_git_detection_never_executes_project_commands(self):
        project = self.root / "repo"
        (project / ".git").mkdir(parents=True)
        (project / ".git" / "config").write_text("untrusted hooks")
        with patch("subprocess.run", side_effect=AssertionError("scan ran a command")):
            result = storage_audit.scan_folder(project)
        self.assertEqual(len(result["git_projects"]), 1)
        self.assertFalse(result["git_projects"][0]["github_backup_verified"])
        self.assertEqual(result["git_projects"][0]["relative_path"], ".")

    def test_bounded_scan_is_marked_incomplete(self):
        folder = self.root / "many"
        folder.mkdir()
        for index in range(140):
            (folder / f"file{index}.txt").write_text("x")
        result = storage_audit.scan_folder(folder, max_entries=100)
        self.assertEqual(result["entries_scanned"], 100)
        self.assertTrue(result["truncated"])
        self.assertFalse(result["complete"])

    @unittest.skipIf(server is None, "Full RelayOS MCP dependencies are unavailable")
    def test_scan_requires_local_once_approval_and_cannot_replay(self):
        folder = self.root / "workspace"
        folder.mkdir()
        (folder / "hi.txt").write_text("hello")
        with patch.object(storage_audit, "permitted_scan_root", return_value=folder):
            proposed = server.propose_storage_scan(str(folder))
            token = proposed["request_id"]
            with self.assertRaises(PermissionError):
                server.scan_approved_storage(token)
            with self.assertRaisesRegex(ValueError, "Approve Once"):
                state.decide_request(token, "persistent")
            state.decide_request(token, "once")
            result = server.scan_approved_storage(token)
            self.assertEqual(result["files_scanned"], 1)
            with self.assertRaises(PermissionError):
                server.scan_approved_storage(token)

    @unittest.skipIf(server is None, "Full RelayOS MCP dependencies are unavailable")
    def test_denial_and_emergency_stop(self):
        with patch.object(storage_audit, "permitted_scan_root", return_value=self.root):
            proposed = server.propose_storage_scan(str(self.root))
            state.decide_request(proposed["request_id"], "deny")
            with self.assertRaises(PermissionError):
                server.scan_approved_storage(proposed["request_id"])
            state.set_emergency_stop(True)
            with self.assertRaises(PermissionError):
                server.propose_storage_scan(str(self.root))
            with self.assertRaises(PermissionError):
                server.disk_storage_overview()


if __name__ == "__main__":
    unittest.main()
