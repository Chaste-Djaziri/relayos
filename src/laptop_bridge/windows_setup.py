"""Best-effort Windows prerequisite provisioning.

The packaged app can run without these helpers, but installing them early makes
the first coding session predictable. No credentials are handled here.
"""
import os
import shutil
import subprocess

from . import ngrok


def is_windows():
    return os.name == "nt"


def missing_prerequisites():
    if not is_windows():
        return []
    missing = []
    if not ngrok.find_executable():
        missing.append(("9MVS1J51GMK6", "msstore"))
    if not shutil.which("git"):
        missing.append(("Git.Git", "winget"))
    return missing


def provision_prerequisites():
    """Start silent winget installs when available; never block the UI."""
    missing = missing_prerequisites()
    winget = shutil.which("winget")
    if not missing or not winget:
        return {"missing": missing, "started": [], "winget": bool(winget)}
    started = []
    for package, source in missing:
        try:
            subprocess.Popen(
                [winget, "install", "--id", package, "--exact", "--source", source,
                 "--silent", "--accept-source-agreements", "--accept-package-agreements"],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
            started.append(package)
        except OSError:
            pass
    return {"missing": missing, "started": started, "winget": True}
