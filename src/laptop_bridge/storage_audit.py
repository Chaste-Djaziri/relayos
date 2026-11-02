# Path: src/laptop_bridge/storage_audit.py
"""Read-only, bounded storage inspection; never opens user file contents."""
from __future__ import annotations

import os
import shutil
import stat
import time
from collections import Counter, defaultdict
from pathlib import Path

CACHE_DIRS = {
    "node_modules": "reinstallable dependencies",
    ".next": "generated web build",
    ".nuxt": "generated web build",
    ".turbo": "generated build cache",
    "__pycache__": "Python bytecode",
    ".pytest_cache": "test cache",
    ".mypy_cache": "type-check cache",
    "deriveddata": "Xcode build artifacts",
    ".build": "generated build artifacts",
    "build": "build output (review first)",
    "dist": "distribution output (review first)",
    ".gradle": "Gradle cache (review first)",
}
KEY_FILES = {"id_rsa", "id_ed25519", "id_ecdsa", "id_dsa", "credentials",
             "credentials.json", "google-services.json", "google-services.plist",
             "service-account.json"}
KEY_EXTENSIONS = {".pem", ".p12", ".pfx", ".key", ".keystore"}

def disk_overview() -> dict:
    """Filesystem total/free space. No folder permission or file access."""
    usage = shutil.disk_usage(Path.home())
    return {"volume": "/", "total_bytes": usage.total,
            "used_bytes": usage.used, "free_bytes": usage.free,
            "used_percent": round(100 * usage.used / usage.total, 1) if usage.total else None,
            "read_only": True}

def permitted_scan_root(folder: str) -> Path:
    """Limit scope even before a human approves a scan."""
    if not isinstance(folder, str) or not folder.strip() or len(folder) > 4096:
        raise ValueError("Specify an existing folder")
    candidate = Path(folder).expanduser()
    if not candidate.is_absolute():
        candidate = Path.home() / candidate
    path = candidate.resolve(strict=True)
    home = Path.home().resolve(strict=True)
    other_roots = (Path("/Applications"), Path("/Library"), Path("/Volumes"))
    if path != home and home not in path.parents and not any(
        root == path or root in path.parents for root in other_roots
    ):
        raise PermissionError("Storage scan must be within home, /Applications, /Library, or /Volumes")
    if not path.is_dir():
        raise ValueError("Storage scan target must be an existing directory")
    return path

def sensitive_kind(name: str) -> str | None:
    name = name.casefold()
    if name == ".env" or name.startswith(".env."):
        return "environment file"
    if name in KEY_FILES:
        return "credential or key filename"
    if Path(name).suffix in KEY_EXTENSIONS:
        return "certificate or key filename"
    return None

def git_metadata(folder: Path) -> dict:
    """Detect a project root without executing project-controlled Git behavior.

    Running git status could trigger an untrusted fsmonitor hook or Git
    extension, so all recovery checks are deliberately left to a separately
    approved project command. Never assume a .git directory is backed up.
    """
    return {"relative_path": None, "git_repository_detected": True,
            "dirty_tracked": None, "untracked": None,
            "has_remote": None, "has_upstream": None,
            "ahead_of_tracking_branch": None, "github_backup_verified": False}

def scan_folder(root: Path, max_entries: int = 25000, max_seconds: float = 10.0,
                max_depth: int = 30) -> dict:
    """Bounded file metadata, no links followed, no reads, writes or network."""
    root = Path(root).resolve(strict=True)
    if not root.is_dir():
        raise ValueError("Expected a directory")
    max_entries = max(100, min(int(max_entries), 50000))
    max_seconds = max(1.0, min(float(max_seconds), 15.0))
    max_depth = max(1, min(int(max_depth), 50))
    started = time.monotonic()
    device = root.stat().st_dev
    stack = [(root, 0)]
    counters = Counter()
    top_sizes = defaultdict(int)
    cache_sizes = defaultdict(int)
    largest = []
    git_roots = set()
    key_markers = Counter()
    key_categories = Counter()
    hardlinks_seen = set()
    size_total = 0
    errors = 0
    truncated = False
    while stack:
        if counters["entries"] >= max_entries or time.monotonic() - started >= max_seconds:
            truncated = True
            break
        folder, depth = stack.pop()
        try:
            iterator = os.scandir(folder)
        except OSError:
            errors += 1
            continue
        with iterator:
            for item in iterator:
                if counters["entries"] >= max_entries or time.monotonic() - started >= max_seconds:
                    truncated = True
                    break
                counters["entries"] += 1
                try:
                    info = item.stat(follow_symlinks=False)
                except OSError:
                    errors += 1
                    continue
                if stat.S_ISLNK(info.st_mode):
                    counters["symlinks_skipped"] += 1
                    continue
                if info.st_dev != device:
                    counters["mounts_skipped"] += 1
                    continue
                rel = Path(item.path).relative_to(root)
                parts = rel.parts
                if stat.S_ISDIR(info.st_mode):
                    counters["directories"] += 1
                    if item.name == ".git":
                        git_roots.add(Path(item.path).parent)
                    if depth + 1 < max_depth:
                        stack.append((Path(item.path), depth + 1))
                    else:
                        counters["depth_limit_skipped"] += 1
                        truncated = True
                    continue
                if not stat.S_ISREG(info.st_mode):
                    counters["special_files_skipped"] += 1
                    continue
                counters["files"] += 1
                if info.st_nlink > 1:
                    inode = (info.st_dev, info.st_ino)
                    if inode in hardlinks_seen:
                        counters["hardlinks_skipped"] += 1
                        continue
                    hardlinks_seen.add(inode)
                size = info.st_size
                size_total += size
                key = sensitive_kind(item.name)
                if key:
                    key_categories[key] += 1
                    key_markers[parts[0]] += 1
                top_sizes[parts[0]] += size
                for index, component in enumerate(parts[:-1]):
                    category = CACHE_DIRS.get(component.casefold())
                    if category:
                        cache_sizes[("/".join(parts[:index + 1]), category)] += size
                        break
                # Do not reveal likely secrets, even through "largest files".
                if not key:
                    largest.append((size, str(rel)))
                    if len(largest) > 30:
                        largest.sort(reverse=True)
                        largest.pop()
        if truncated:
            break
    projects = []
    # Avoid a large git status scan delaying MCP. No network calls, ever.
    for path in sorted(git_roots)[:12]:
        if time.monotonic() - started >= max_seconds + 12:
            truncated = True
            break
        report = git_metadata(path)
        report["relative_path"] = str(path.relative_to(root)) or "."
        projects.append(report)
    return {
        "root": str(root), "read_only": True,
        "complete": not truncated and errors == 0,
        "truncated": truncated, "unreadable_directories": errors,
        "scan_seconds": round(time.monotonic() - started, 2),
        "logical_bytes_scanned": size_total,
        "entries_scanned": counters["entries"],
        "files_scanned": counters["files"],
        "directories_scanned": counters["directories"],
        "symlinks_skipped": counters["symlinks_skipped"],
        "mounts_skipped": counters["mounts_skipped"],
        "hardlinks_skipped": counters["hardlinks_skipped"],
        "top_level": [
            {"name": name if not sensitive_kind(name) else "[sensitive]",
             "logical_bytes_scanned": size, "credential_markers": key_markers[name]}
            for name, size in sorted(top_sizes.items(), key=lambda x: x[1], reverse=True)[:35]
        ],
        "largest_files": [{"relative_path": name, "bytes": size}
                          for size, name in sorted(largest, reverse=True)[:25]],
        "cache_candidates": [
            {"relative_path": path, "category": category,
             "logical_bytes_scanned": size, "requires_review": True}
            for (path, category), size in
            sorted(cache_sizes.items(), key=lambda x: x[1], reverse=True)[:35]
        ],
        "credential_filename_markers": dict(key_categories),
        "git_projects": projects,
        "git_projects_truncated": len(git_roots) > len(projects),
        "warnings": [
            "Scanned logical sizes can differ from physical disk usage and undercount when incomplete.",
            "A git remote or local upstream does not prove a project is recoverable from GitHub.",
            "Check ignored files, local databases, untracked work, and private keys before deleting a project.",
            "No file contents, secrets, deletions or network calls were performed."
        ]
    }
