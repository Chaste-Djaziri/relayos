# Path: src/laptop_bridge/file_management.py
"""Scoped macOS file/app metadata and explicitly approved file operations.

No shell supplied by clients, no file contents returned, no automatic deletion.
"""
from __future__ import annotations

import os
import plistlib
import shutil
import stat
import subprocess
import time
from pathlib import Path

from .storage_audit import permitted_scan_root, sensitive_kind

MAX_BATCH = 10
MAX_COPY_BYTES = 200 * 1024 * 1024

def root_for_session(session_id: str) -> Path:
    from .state import file_access_session
    return permitted_scan_root(file_access_session(session_id)["root"])

def _path(raw: str, root: Path, *, exists: bool = True) -> Path:
    if not isinstance(raw, str) or not raw.strip() or len(raw) > 4096 or "\x00" in raw:
        raise ValueError("Invalid file path")
    base = Path(raw).expanduser()
    p = base if base.is_absolute() else root / base
    # Reject symlink traversal before resolve. Never follow symlinks into
    # external folders, even when realpath happens to end within scope.
    p = Path(os.path.abspath(p))
    cursor = p
    while True:
        if cursor.is_symlink():
            raise PermissionError("Symlinks are not supported by file-manager actions")
        if cursor == cursor.parent:
            break
        cursor = cursor.parent
    resolved = p.resolve(strict=exists)
    if not (resolved == root or root in resolved.parents):
        raise PermissionError("Path outside the approved file management folder")
    if exists and not p.exists():
        raise FileNotFoundError("Item no longer exists")
    return resolved

def _fingerprint(path: Path) -> list[int]:
    info = path.lstat()
    return [info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns]

def _type(info) -> str:
    if stat.S_ISDIR(info.st_mode):
        return "app" if str(getattr(info, "filename", "")).endswith(".app") else "directory"
    if stat.S_ISREG(info.st_mode):
        return "file"
    if stat.S_ISLNK(info.st_mode):
        return "symlink"
    return "other"

def _app_info(path: Path) -> dict | None:
    if not path.name.lower().endswith(".app") or not path.is_dir():
        return None
    info_file = path / "Contents/Info.plist"
    try:
        if info_file.stat().st_size > 262144:
            return None
        with info_file.open("rb") as handle:
            data = plistlib.load(handle)
        return {
            "bundle_identifier": str(data.get("CFBundleIdentifier", ""))[:200],
            "display_name": str(data.get("CFBundleDisplayName") or data.get("CFBundleName") or path.stem)[:180],
            "version": str(data.get("CFBundleShortVersionString", ""))[:80],
        }
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException):
        return None

def entry(path: Path, *, short_name: bool = False) -> dict:
    info = path.lstat()
    kind = "app" if stat.S_ISDIR(info.st_mode) and path.name.endswith(".app") else (
        "directory" if stat.S_ISDIR(info.st_mode) else
        "file" if stat.S_ISREG(info.st_mode) else
        "symlink" if stat.S_ISLNK(info.st_mode) else "other")
    value = {
        "name": path.name if not sensitive_kind(path.name) else "[sensitive filename]",
        "path": str(path) if not sensitive_kind(path.name) else "[sensitive path]",
        "kind": kind,
        "size_bytes": info.st_size if kind == "file" else None,
        "modified_at": info.st_mtime,
        "created_at": info.st_birthtime if hasattr(info, "st_birthtime") else info.st_ctime,
        "hidden": path.name.startswith("."),
        "sensitive_filename": bool(sensitive_kind(path.name)),
        "writable": os.access(path, os.W_OK),
    }
    if not short_name and kind == "app":
        value["app"] = _app_info(path)
    return value

def list_directory(session_id: str, folder: str = ".", offset: int = 0,
                   limit: int = 75, show_hidden: bool = False) -> dict:
    root = root_for_session(session_id)
    p = _path(folder, root)
    if not p.is_dir():
        raise ValueError("Not a directory")
    offset = max(0, min(int(offset), 100000))
    limit = max(1, min(int(limit), 100))
    results = []
    with os.scandir(p) as stream:
        for item in stream:
            if not show_hidden and item.name.startswith("."):
                continue
            # Do not follow symlinks or open file contents.
            results.append(item.name)
            if len(results) > 5000:
                break
    results.sort(key=str.casefold)
    items = []
    for name in results[offset:offset + limit]:
        try:
            items.append(entry(p / name))
        except OSError:
            continue
    return {"folder": str(p), "items": items, "offset": offset,
            "next_offset": offset + limit if len(results) > offset + limit else None,
            "total_listed": len(results), "truncated": len(results) > 5000,
            "read_only": True}

def details(session_id: str, path: str) -> dict:
    root = root_for_session(session_id)
    p = _path(path, root)
    item = entry(p)
    if item["kind"] in ("directory", "app"):
        try:
            with os.scandir(p) as stream:
                item["at_least_children"] = sum(1 for _, x in zip(range(501), stream))
        except OSError:
            item["at_least_children"] = None
        item["directory_size_bytes"] = None
    item["recovery_note"] = "Local or GitHub recovery has not been verified."
    return item

def search(session_id: str, query: str, *, limit: int = 80) -> dict:
    if not isinstance(query, str) or not (1 <= len(query.strip()) <= 100):
        raise ValueError("Provide a short filename query")
    root = root_for_session(session_id)
    query = query.casefold()
    limit = max(1, min(int(limit), 100))
    stack = [root]
    matches = []
    entries_seen = 0
    started = time.monotonic()
    truncated = False
    while stack:
        if entries_seen >= 10000 or time.monotonic() - started >= 5:
            truncated = True
            break
        folder = stack.pop()
        try:
            iterator = os.scandir(folder)
        except OSError:
            continue
        with iterator:
            for item in iterator:
                entries_seen += 1
                if entries_seen >= 10000 or time.monotonic() - started >= 5:
                    truncated = True
                    break
                if item.is_symlink():
                    continue
                if query in item.name.casefold() and not sensitive_kind(item.name):
                    try:
                        matches.append(entry(Path(item.path), short_name=True))
                    except OSError:
                        pass
                    if len(matches) >= limit:
                        truncated = True
                        break
                if item.is_dir(follow_symlinks=False) and item.name not in {
                    ".git", "node_modules", ".Trash", ".laptop-bridge", ".ssh",
                    ".gnupg", "Library", ".venv"
                } and not item.name.endswith(".app"):
                    stack.append(Path(item.path))
        if truncated:
            break
    return {"root": str(root), "query": query, "matches": matches,
            "entries_scanned": entries_seen, "truncated": truncated, "read_only": True}

def installed_apps(session_id: str, *, offset: int = 0, limit: int = 75) -> dict:
    root = root_for_session(session_id)
    apps = []
    truncated = False
    started = time.monotonic()
    candidates = (Path("/Applications"), Path.home() / "Applications",
                  Path("/System/Applications"))
    for candidate in candidates:
        if not (candidate == root or root in candidate.parents):
            continue
        if not candidate.is_dir():
            continue
        stack = [(candidate, 0)]
        seen = 0
        while stack:
            if time.monotonic() - started > 4 or seen > 5000:
                truncated = True
                break
            folder, depth = stack.pop()
            try:
                iterator = os.scandir(folder)
            except OSError:
                continue
            with iterator:
                for item in iterator:
                    seen += 1
                    try:
                        if item.is_symlink() or not item.is_dir(follow_symlinks=False):
                            continue
                        if item.name.endswith(".app"):
                            apps.append(entry(Path(item.path)))
                        elif depth < 3:
                            stack.append((Path(item.path), depth + 1))
                    except OSError:
                        continue
    apps.sort(key=lambda i: i["name"].casefold())
    offset = max(0, int(offset))
    limit = max(1, min(int(limit), 100))
    return {"apps": apps[offset:offset + limit], "total": len(apps),
            "next_offset": offset + limit if offset + limit < len(apps) else None,
            "truncated": truncated, "read_only": True,
            "note": "Moving an .app bundle to Trash is not a complete uninstall; its support files and login items may remain."}


def developer_tools(session_id: str) -> dict:
    """Find common installed command-line tools without executing their code.

    Package-manager uninstallation is intentionally NOT an unscoped file delete.
    """
    root_for_session(session_id)
    names = ("git", "swift", "xcodebuild", "python3", "node", "npm",
             "npx", "pnpm", "yarn", "bun", "brew", "docker", "kubectl",
             "terraform", "java", "gradle", "cmake", "rustc", "cargo",
             "go", "dart", "flutter")
    items = []
    for name in names:
        found = shutil.which(name)
        if not found:
            continue
        try:
            path = Path(found)
            meta = path.lstat()
            items.append({"tool": name, "executable_path": str(path),
                          "is_symlink": path.is_symlink(),
                          "size_bytes": meta.st_size if stat.S_ISREG(meta.st_mode) else None})
        except OSError:
            continue
    return {"tools": items, "read_only": True,
            "removal_note": "CLI tools should be removed through their package manager after explicit review, not by deleting their executables."}


def _protected(path: Path, root: Path) -> None:
    home = Path.home().resolve()
    # Never allow a broad parent to be moved, and never allow anything under
    # credential, system, or live RelayOS application/state trees.
    protected_roots = [
        home, home / "Documents", home / "Downloads", home / "Desktop",
        home / "Pictures", home / "Movies", home / "Music", home / "Library",
        home / ".Trash", home / ".ssh", home / ".gnupg", home / ".laptop-bridge",
        home / "Applications", Path("/Applications"), Path("/Library"),
        Path("/Volumes"), Path("/Users"), Path("/System"),
        Path("/usr"), Path("/bin"), Path("/sbin"),
        home / "Documents/GitHub/laptop-bridge",
        Path("/Applications/RelayOS.app"),
    ]
    protected_trees = [
        home / "Library", home / ".Trash", home / ".ssh", home / ".gnupg",
        home / ".laptop-bridge",
        home / "Documents/GitHub/laptop-bridge",
        Path("/Applications/RelayOS.app"), Path("/System"), Path("/Library"),
        Path("/usr"), Path("/bin"), Path("/sbin"),
    ]
    if path == root or any(path == p or path in p.parents for p in protected_roots):
        raise PermissionError("Protected root/system/RelayOS folder cannot be modified")
    if any(path == p or p in path.parents for p in protected_trees):
        raise PermissionError("File lies inside a protected system or credentials folder")
    if any(sensitive_kind(part) or part in {".git", ".ssh", ".gnupg",
                                          ".Trash", ".laptop-bridge"} for part in path.parts):
        raise PermissionError("Protected credential or repository-internal file")
    if path.name.endswith(".app"):
        if not (path.parent == Path("/Applications") or path.parent == home / "Applications"):
            raise PermissionError("Only user-level Applications can be trashed")
        app = _app_info(path)
        if app and app["bundle_identifier"].startswith("com.apple."):
            raise PermissionError("Apple system apps cannot be removed through RelayOS")

def _check_trash_directory(path: Path) -> None:
    """Don't silently trash repos, hidden keys or unreviewably huge folders.

    App bundles are specifically reviewed through bundle-ID and local Once
    approval; their bundled resources are not independently scanned as documents.
    """
    if not path.is_dir() or path.name.endswith(".app"):
        return
    stack = [path]
    visited = 0
    started = time.monotonic()
    while stack:
        if visited >= 3000 or time.monotonic() - started > 3.0:
            raise PermissionError("Folder is too large to safely preflight; review it in Finder")
        folder = stack.pop()
        with os.scandir(folder) as stream:
            for item in stream:
                visited += 1
                if item.is_symlink():
                    raise PermissionError("Folder contains a symbolic link; review in Finder")
                if item.name == ".git" or sensitive_kind(item.name) or item.name in {
                    ".ssh", ".gnupg", ".laptop-bridge", ".Trash"
                }:
                    raise PermissionError("Folder contains Git data or credential-like files; verify backups in Finder")
                if item.is_dir(follow_symlinks=False):
                    stack.append(Path(item.path))


def prepare(action: str, session_id: str, paths: list[str],
            destination: str | None = None) -> dict:
    if action not in {"trash", "move", "copy", "rename", "mkdir"}:
        raise ValueError("Unsupported file operation")
    if not isinstance(paths, list) or not 1 <= len(paths) <= MAX_BATCH:
        raise ValueError("Choose between 1 and 10 exact paths")
    if action != "trash" and len(paths) != 1:
        raise ValueError("This operation supports exactly one item")
    root = root_for_session(session_id)
    items = []
    for raw in paths:
        p = _path(raw, root, exists=(action != "mkdir"))
        _protected(p, root)
        if action == "mkdir":
            if p.exists() or not p.parent.is_dir():
                raise ValueError("Folder already exists or parent is missing")
        else:
            items.append({"path": str(p), "fingerprint": _fingerprint(p)})
    if len(set(item["path"] for item in items)) != len(items):
        raise ValueError("Duplicate selected items")
    if action == "trash":
        for item in items:
            _check_trash_directory(Path(item["path"]))
        for a in items:
            for b in items:
                if a != b and Path(a["path"]) in Path(b["path"]).parents:
                    raise ValueError("Do not select a folder and its child together")
    dest = None
    if action == "mkdir":
        dest = str(p)
    elif action in {"move", "copy", "rename"}:
        if not destination:
            raise ValueError("A destination path is required")
        d = _path(destination, root, exists=False)
        _protected(d, root)
        if d.exists() or not d.parent.is_dir():
            raise FileExistsError("Destination exists or parent is missing")
        if action == "rename" and d.parent != Path(items[0]["path"]).parent:
            raise ValueError("Rename must keep the same parent")
        if d == Path(items[0]["path"]) or Path(items[0]["path"]) in d.parents:
            raise PermissionError("Cannot nest an item inside itself")
        dest = str(d)
    return {"action": action, "session_id": session_id, "root": str(root),
            "items": items, "destination": dest}

def _safe_copy(src: Path, dest: Path) -> None:
    """Preflight a bounded copy to avoid following arbitrary links or huge jobs."""
    queue = [src]
    total = 0
    entries = 0
    while queue:
        p = queue.pop()
        if p.is_symlink() or sensitive_kind(p.name):
            raise PermissionError("Copies containing symbolic links or credential-like files are not supported")
        entries += 1
        if entries > 2000:
            raise ValueError("Copy exceeds 2000 items")
        if p.is_dir():
            with os.scandir(p) as iterator:
                queue.extend(Path(child.path) for child in iterator)
        else:
            total += p.stat().st_size
            if total > MAX_COPY_BYTES:
                raise ValueError("Copy exceeds 200 MiB safety limit")
    if src.is_dir():
        shutil.copytree(src, dest, symlinks=True)
    else:
        # Exclusive creation prevents a race from overwriting a new file.
        with src.open("rb") as reader, dest.open("xb") as writer:
            shutil.copyfileobj(reader, writer, length=1024 * 1024)
        shutil.copystat(src, dest, follow_symlinks=False)

def _trash(path: Path) -> None:
    """Use the system Trash API, rather than unlink or shutil.rmtree."""
    try:
        from Foundation import NSFileManager, NSURL
    except ImportError as exc:
        raise RuntimeError("macOS Trash API unavailable; nothing was removed") from exc
    url = NSURL.fileURLWithPath_(str(path))
    ok, _trash_url, error = NSFileManager.defaultManager().trashItemAtURL_resultingItemURL_error_(
        url, None, None)
    if not ok:
        raise OSError(str(error) if error else "macOS refused to move this item to Trash")

def execute(plan: dict) -> dict:
    root = root_for_session(plan["session_id"])
    if str(root) != plan["root"]:
        raise PermissionError("Approval scope changed")
    action = plan["action"]
    if action not in {"trash", "move", "copy", "rename", "mkdir"}:
        raise PermissionError("Invalid approved action")
    for item in plan["items"]:
        p = _path(item["path"], root)
        _protected(p, root)
        if _fingerprint(p) != item["fingerprint"]:
            raise PermissionError("Item changed since approval; request a new approval")
    if plan["destination"]:
        dest = _path(plan["destination"], root, exists=False)
        _protected(dest, root)
        if action == "mkdir":
            if dest.exists() or not dest.parent.is_dir():
                raise FileExistsError("Destination changed since approval")
        elif dest.exists() or not dest.parent.is_dir():
            raise FileExistsError("Destination changed since approval")
    result = []
    if action == "mkdir":
        Path(plan["destination"]).mkdir()
        result.append({"action": "created_folder", "destination": plan["destination"]})
    elif action == "trash":
        for item in plan["items"]:
            path = Path(item["path"])
            try:
                _trash(path)
                result.append({"action": "moved_to_trash", "path": str(path), "success": True})
            except Exception as exc:
                result.append({"action": "moved_to_trash", "path": str(path),
                               "success": False, "error": str(exc)[:250]})
    else:
        src = Path(plan["items"][0]["path"])
        dst = Path(plan["destination"])
        if action == "copy":
            _safe_copy(src, dst)
        else:
            # os.rename never silently copies across volumes, or overwrites
            # an existing destination in our pre-check.
            src.rename(dst)
        result.append({"action": action, "source": str(src), "destination": str(dst),
                       "success": True})
    return {"action": action, "results": result,
            "successful": sum(x.get("success", True) for x in result),
            "failed": sum(not x.get("success", True) for x in result)}

def trash_preview() -> dict:
    home_trash = Path.home() / ".Trash"
    names = []
    try:
        with os.scandir(home_trash) as iterator:
            for item in iterator:
                names.append(item.name)
                if len(names) >= 2000:
                    break
    except OSError:
        return {"visible_home_trash_items": None, "other_volumes": "unknown"}
    return {"visible_home_trash_items": len(names), "other_volumes": "not inventoried",
            "warning": "Finder Empty Trash permanently removes ALL Trash items on ALL volumes, including items not moved by RelayOS."}

def empty_finder_trash() -> dict:
    """Unrecoverable, global macOS action. Caller MUST enforce typed local approval."""
    if os.uname().sysname != "Darwin":
        raise RuntimeError("Empty Trash is available only on macOS")
    result = subprocess.run(["/usr/bin/osascript", "-e",
                             'tell application "Finder" to empty trash'],
                            stdin=subprocess.DEVNULL, capture_output=True,
                            text=True, timeout=120, check=False, shell=False)
    if result.returncode:
        raise RuntimeError("Finder did not empty Trash: " + result.stderr.strip()[:300])
    return {"emptied": True, "scope": "Finder Trash on all volumes",
            "recoverable": False}
