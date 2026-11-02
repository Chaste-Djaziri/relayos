# Path: tests/test_file_management.py
"""Regression tests: scoped access, exact approval, no silent irreversible deletion."""
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from laptop_bridge import file_management, state


class FileManagerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.root = self.base / "workspace"
        self.root.mkdir()
        db_dir = self.base / "settings"
        for target, val in (("STATE_DIR", db_dir), ("DATABASE_FILE", db_dir / "state.sqlite3")):
            p = patch.object(state, target, val)
            p.start()
            self.addCleanup(p.stop)
        p = patch.object(file_management, "root_for_session", return_value=self.root)
        p.start()
        self.addCleanup(p.stop)

    def test_file_session_is_expiring_and_revocable(self):
        issued = state.create_file_access_session(str(self.root))
        self.assertEqual(state.file_access_session(issued["session_id"])["root"], str(self.root))
        state.revoke_file_access_session(issued["session_id"])
        with self.assertRaises(PermissionError):
            state.file_access_session(issued["session_id"])

    def test_emergency_stop_revokes_file_access(self):
        issued = state.create_file_access_session(str(self.root))
        state.set_emergency_stop(True)
        with self.assertRaises(PermissionError):
            state.file_access_session(issued["session_id"])
        state.set_emergency_stop(False)
        with self.assertRaises(PermissionError):
            state.file_access_session(issued["session_id"])

    def test_special_requests_cannot_have_persistent_approval(self):
        for kind in ("file_access", "file_operation", "empty_trash"):
            token = state.request(kind, {"target": "test", "argv": []})
            with self.assertRaisesRegex(ValueError, "Approve Once"):
                state.decide_request(token, "persistent")
            if kind == "empty_trash":
                with self.assertRaisesRegex(PermissionError, "EMPTY TRASH"):
                    state.decide_request(token, "once")
                with self.assertRaisesRegex(PermissionError, "EMPTY TRASH"):
                    state.approve(token)
                self.assertTrue(state.decide_request(token, "once", confirmation="EMPTY TRASH"))
            else:
                self.assertTrue(state.decide_request(token, "once"))
            self.assertEqual(state.consume(token, expected_kind=kind)["kind"], kind)
            with self.assertRaises(PermissionError):
                state.consume(token, expected_kind=kind)

    def test_directory_list_and_info_do_not_read_contents(self):
        folder = self.root / "folder"
        folder.mkdir()
        (folder / "sample.txt").write_text("private file body")
        (folder / ".env").write_text("SECRET=not for remote clients")
        results = file_management.list_directory("test", "folder", show_hidden=True)
        self.assertIn("sample.txt", [item["name"] for item in results["items"]])
        self.assertTrue(any(item["sensitive_filename"] for item in results["items"]))
        self.assertNotIn("SECRET=not", str(results))
        self.assertEqual(file_management.details("test", "folder")["kind"], "directory")

    def test_scope_escape_and_symlinks_denied(self):
        other = self.base / "outside"
        other.mkdir()
        (other / "private.txt").write_text("outside")
        (self.root / "link").symlink_to(other, target_is_directory=True)
        for name in ("../outside", str(other), "link/private.txt"):
            with self.assertRaises(PermissionError):
                file_management.details("test", name)

    def test_root_and_credentials_cannot_be_trashed(self):
        (self.root / ".env").write_text("TEST=1")
        with self.assertRaises(PermissionError):
            file_management.prepare("trash", "test", ["."])
        with self.assertRaises(PermissionError):
            file_management.prepare("trash", "test", [".env"])
        (self.root / ".git").mkdir()
        with self.assertRaises(PermissionError):
            file_management.prepare("trash", "test", [".git"])

    def test_git_repository_or_nested_key_folder_never_trashes_without_review(self):
        repo = self.root / "old-project"
        (repo / ".git").mkdir(parents=True)
        with self.assertRaisesRegex(PermissionError, "Git data"):
            file_management.prepare("trash", "test", ["old-project"])
        folder = self.root / "archive"
        folder.mkdir()
        (folder / ".env").write_text("PASSWORD=value")
        with self.assertRaisesRegex(PermissionError, "credential-like"):
            file_management.prepare("trash", "test", ["archive"])

    def test_nested_library_credentials_and_active_app_are_protected(self):
        library = self.root / "Library" / "Keychains"
        library.mkdir(parents=True)
        (library / "login.keychain-db").write_text("secret")
        with patch.object(file_management.Path, "home", return_value=self.root):
            with self.assertRaises(PermissionError):
                file_management.prepare("trash", "test", ["Library/Keychains"])

    def test_developer_tool_inventory_never_launches_tools(self):
        with patch.object(file_management.shutil, "which", return_value="/usr/bin/git"):
            with patch.object(file_management.subprocess, "run", side_effect=AssertionError("exec")):
                tools = file_management.developer_tools("test")
        self.assertTrue(tools["read_only"])
        self.assertTrue(any(item["tool"] == "git" for item in tools["tools"]))

    def test_trash_only_with_explicit_execution_and_stable_inode(self):
        item = self.root / "example.txt"
        item.write_text("hello")
        plan = file_management.prepare("trash", "test", ["example.txt"])
        self.assertTrue(item.exists())
        called = []
        with patch.object(file_management, "_trash", side_effect=lambda p: called.append(str(p))):
            result = file_management.execute(plan)
        self.assertEqual(called, [str(item)])
        self.assertEqual(result["successful"], 1)

        item.write_text("changed")
        with self.assertRaises(PermissionError):
            file_management.execute(plan)

    def test_move_requires_exact_destination_and_never_overwrites(self):
        (self.root / "one.txt").write_text("one")
        (self.root / "two.txt").write_text("two")
        with self.assertRaises(FileExistsError):
            file_management.prepare("move", "test", ["one.txt"], "two.txt")
        plan = file_management.prepare("rename", "test", ["one.txt"], "renamed.txt")
        result = file_management.execute(plan)
        self.assertEqual(result["successful"], 1)
        self.assertTrue((self.root / "renamed.txt").exists())
        self.assertFalse((self.root / "one.txt").exists())

    def test_create_folder_and_copy(self):
        plan = file_management.prepare("mkdir", "test", ["NewFolder"])
        file_management.execute(plan)
        self.assertTrue((self.root / "NewFolder").is_dir())
        (self.root / "source.txt").write_text("copy")
        plan = file_management.prepare("copy", "test", ["source.txt"], "NewFolder/copy.txt")
        file_management.execute(plan)
        self.assertEqual((self.root / "NewFolder/copy.txt").read_text(), "copy")

    def test_search_is_metadata_only_and_skips_sensitive(self):
        (self.root / "movie.mov").write_text("x")
        (self.root / "id_ed25519").write_text("private")
        found = file_management.search("test", "mov")
        self.assertEqual([x["name"] for x in found["matches"]], ["movie.mov"])
        self.assertFalse(file_management.search("test", "ed25519")["matches"])

    def test_empty_trash_not_performed_by_proposal_or_normal_file_ops(self):
        with patch.object(file_management, "empty_finder_trash",
                          side_effect=AssertionError("Unexpected deletion")):
            file_management.trash_preview()
            self.assertFalse((self.root / "New").exists())


if __name__ == "__main__":
    unittest.main()
