# Path: src/laptop_bridge/storage_audit.py
"""Bounded, metadata-only storage inspection. Never opens file contents or deletes files."""
from __future__ import annotations

import os
import shutil
import stat
import subprocess
import time
from collections import Counter, defaultdict
from pathlib import Path

CACHE_DIRECTORIES = {
    "node_modules": "reinstallable dependencies",
    ".next": "generated web build",
    ".nuxt": "generated web build",
    ".turbo": "generated build cache",
    ".cache": "application/developer cache (review)",
    "__pycache__": "generated Python bytecode",
    ".pytest_cache": "test cache",
    ".mypy_cache": "type-check cache",
    ".gradle": "Gradle cache (review)",
    "deriveddata": "Xcode build artifacts",
    ".build": "generated build artifacts (review)",
    "build": "build output (review)",
    "dist": "distribution output (review before deleting)",
}
SENSITIVE_FILENAMES = {"id_rsa", "id_ed25519", "id_ecdsa", "id_dsa",
                       "credentials", "credentials.json", "google-services.json",
                       "google-services.plist", "service-account.json", "key.json"}
SENSITIVE_SUFFIXES = {".pem", ".p12", ".pfx", ".key", ".keystore"}


def disk_overview() -> dict:
    """Filesystem space, without collecting or revealing user file names."""
    home = Path.home()
    usage = shutil.disk_usage(home)
    return {"volume": str(home.anchor), "total_bytes": usage.total,
            "used_bytes": usage.used, "free_bytes": usage.free,
            "used_percent": round(usage.used * 100 / usage.total, 1) if usage.total else None,
            "read_only": True}


def permitted_scan_root(folder: str) -> Path:
    """No implicit arbitrary-root or system-wide scan. Approval is still required."""
    if not isinstance(folder, str) or not folder.strip() or len(folder) > 4096:
        raise ValueError("Specify an existing folder")
    candidate = Path(folder).expanduser()
    if not candidate.is_absolute():
        candidate = Path.home() / candidate
    # Avoid approval over filesystem root or protected system directories.
    path = candidate.resolve(strict=True)
    home = Path.home().resolve(strict=True)
    public_roots = (Path("/Applications"), Path("/Library"))
    if path != home and home not in path.parents and not any(
        path == root or root in path.parents for root in public_roots
    ):
        raise PermissionError("Choose a folder in your home, /Applications, or /Library")
    if not path.is_dir():
        raise ValueError("Storage scan target must be a directory")
    return path


def _secret_category(name: str) -> str | None:
    lower = name.casefold()
    if lower == ".env" or lower.startswith(".env."):
        return "environment file"
    if lower in SENSITIVE_FILENAMES:
        return "credential/key filename"
    if Path(lower).suffix in SENSITIVE_SUFFIXES:
        return "certificate/private-key filename"
    return None


def _git_result(repo: Path) -> dict:
    """Local git metadata only; never uses fetch or reads key/remote URL contents."""
    result = {"path": str(repo), "checked": False, "remote_configured": False,
              "upstream_configured": False, "local_changes": None,
              "untracked_items": None, "commits_ahead": None,
              "recoverable_from_github": "not_verified"}
    def run(*args):
        try:
            p = subprocess.run(["git", "-C", str(repo), *args],
                               stdin=subprocess.DEVNULL, capture_output=True,
                               timeout=2, check=False, shell=False)
            return p.stdout.decode("utf-8", errors="replace") if p.returncode == 0 else None
        except (OSError, subprocess.TimeoutExpired):
            return None
    # Skip expensive inspection of arbitrary huge repositories.
    status = run("status", "--porcelain=v1", "--untracked-files=normal")
    if status is None:
        return result
    lines = status.splitlines()
    result["checked"] = True
    result["local_changes"] = sum(not x.startswith("??") for x in lines)
    result["untracked_items"] = sum(x.startswith("??") for x in lines)
    remote = run("remote")
    result["remote_configured"] = bool(remote and remote.strip())
    upstream = run("rev-parse", "--verify", "@{upstream}")
    result["upstream_configured"] = bool(upstream and upstream.strip())
    if result["upstream_configured"]:
        ahead = run("rev-list", "--count", "@{upstream}..HEAD")
        if ahead and ahead.strip().isdigit():
            result["commits_ahead"] = int(ahead.strip())
    # An offline tracking ref cannot prove that GitHub still has the commit.
    return result


def scan_folder(root: Path, *, max_entries: int = 30000,
                max_seconds: float = 12.0, max_depth: int = 32) -> dict:
    """Scan file metadata with strict bounds; no symlinks or mounted volumes followed.

    Results can be partial. No recommendation represents permission to delete.
    Names such as .env and private keys are classified, never opened or returned.
    """
    root = Path(root).resolve(strict=True)
    if not root.is_dir():
        raise ValueError("Expected an existing directory")
    max_entries = max(100, min(int(max_entries), 60000))
    max_seconds = max(1.0, min(float(max_seconds), 20.0))
    max_depth = max(1, min(int(max_depth), 64))
    started = time.monotonic()
    root_device = root.stat().st_dev
    stack = [(root, 0)]
    counts = Counter()
    top_bytes = defaultdict(int)
    cache_bytes = defaultdict(int)
    large_files = []
    git_roots = set()
    secrets_by_project = Counter()
    sensitive_categories = Counter()
    total_bytes = 0
    visited_inodes = set()
    errors = 0
    complete = True

    while stack:
        if counts["entries"] >= max_entries or time.monotonic() - started >= max_seconds:
            complete = False
            break
        folder, depth = stack.pop()
        try:
            with os.scandir(folder) as scan:
                children = list(scan)
        except OSError:
            errors += 1
            continue
        for item in children:
            if counts["entries"] >= max_entries or time.monotonic() - started >= max_seconds:
                complete = False
                break
            counts["entries"] += 1
            try:
                info = item.stat(follow_symlinks=False)
            except OSError:
                errors += 1
                continue
            if stat.S_ISLNK(info.st_mode):
                counts["symlinks_skipped"] += 1
                continue
            if info.st_dev != root_device:
                counts["other_volumes_skipped"] += 1
                continue
            path = Path(item.path)
            relative = path.relative_to(root)
            parts = relative.parts
            if stat.S_ISDIR(info.st_mode):
                counts["directories"] += 1
                if item.name == ".git":
                    git_roots.add(path.parent)
                if depth + 1 < max_depth:
                    stack.append((path, depth + 1))
                else:
                    complete = False
                    counts["depth_limit_skipped"] += 1
                continue
            if not stat.S_ISREG(info.st_mode):
                counts["special_files_skipped"] += 1
                continue
            counts["files"] += 1
            if info.st_nlink > 1:
                inode = (info.st_dev, info.st_ino)
                if inode in visited_inodes:
                    counts["hardlinks_skipped"] += 1
                    continue
                visited_inodes.add(inode)
            size = info.st_size
            total_bytes += size
            top_bytes[parts[0]] += size
            for n, component in enumerate(parts[:-1]):
                cache_type = CACHE_DIRECTORIES.get(component.casefold())
                if cache_type:
                    cache_path = "/".join(parts[:n + 1])
                    cache_bytes[(cache_path, cache_type)] += size
                    break
            if len(large_files) < 40:
                large_files.append((size, str(relative)))
                large_files.sort(reverse=True)
            elif size > large_files[-1][0]:
                large_files[-1] = (size, str(relative))
                large_files.sort(reverse=True)
            secret = _secret_category(item.name)
            if secret:
                sensitive_categories[secret] += 1
                # Only counts; never disclose secret filenames, values, or paths.
                secrets_by_project[parts[0]] += 1
        if not complete:
            break

    projects = []
    for folder in sorted(git_roots)[:30]:
        projects.append(_git_result(folder))
    return {
        "root": str(root),
        "read_only": True,
        "complete": complete and errors == 0,
        "truncated": not complete,
        "scan_seconds": round(time.monotonic() - started, 2),
        "scanned_bytes": total_bytes,
        "entries_scanned": counts["entries"],
        "files_scanned": counts["files"],
        "directories_scanned": counts["directories"],
        "symlinks_skipped": counts["symlinks_skipped"],
        "other_volumes_skipped": counts["other_volumes_skipped"],
        "hardlinks_skipped": counts["hardlinks_skipped"],
        "unreadable_directories": errors,
        "top_level": [{"name": name, "scanned_bytes": size,
                       "secret_marker_count": secrets_by_project[name]}
                      for name, size in sorted(top_bytes.items(),
                                               key=lambda x: x[1], reverse=True)[:40]],
        "largest_files": [{"relative_path": name, "bytes": size}
                          for size, name in large_files[:30]],
        "cache_candidates": [{"relative_path": name, "category": category,
                              "scanned_bytes": size, "requires_review": True}
                             for (name, category), size in sorted(cache_bytes.items(),
                                          key=lambda x: x[1], reverse=True)[:40]],
        "credential_file_markers": dict(sensitive_categories),
        "git_projects": projects,
        "git_projects_truncated": len(git_roots) > 30,
        "warnings": [
            "File sizes are scanned logical bytes, not physical allocated disk space.",
            "Truncated scans undercount storage; Git tracking refs are offline and do not prove GitHub backup.",
            "Do not delete projects unless remote recovery, untracked files and secret backups are independently verified.",
            "No deletion, file-content reading, credential export, or network operation was performed."
        ]
    }
