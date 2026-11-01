# Path: scripts/deploy_verified_relayos.py
"""One-shot signed RelayOS hybrid handover with verified rollback.

Usage (from repository root):
  .venv/bin/python scripts/deploy_verified_relayos.py

The foreground phase verifies the staged app and tests both packaged helpers
on temporary state/ports. The actual install occurs in a detached child so
the MCP server can shut down without killing the installation process.
No files below ~/.laptop-bridge are modified by this script.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
STAGED = ROOT / "dist/RelayOS.app"
INSTALLED = Path("/Applications/RelayOS.app")
STATE = Path.home() / ".laptop-bridge"
LOG_DIR = ROOT / "dist/screen-capture-handover"
STATUS = LOG_DIR / "handover-status.json"
LOG = LOG_DIR / "handover.log"
EXEC_REL = "Contents/MacOS/RelayOS"
BUNDLE_ID = "pro.micorp.relayos"


def run(args: list[str], *, timeout: int = 120) -> str:
    result = subprocess.run(args, cwd=ROOT, text=True, capture_output=True,
                            timeout=timeout, check=False)
    if result.returncode:
        raise RuntimeError(f"{args[0]} exited {result.returncode}: {result.stderr[-1200:]}")
    return result.stdout


def check_bundle(app: Path) -> None:
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise RuntimeError(f"Unexpected bundle identifier: {info.get('CFBundleIdentifier')}")
    for relative in (EXEC_REL, "Contents/Resources/Runtime/RelayOSMCPServer",
                     "Contents/Resources/Runtime/RelayOSApprovals",
                     "Contents/Resources/Runtime/RelayOSScreenCapture"):
        path = app / relative
        if not path.is_file() or not os.access(path, os.X_OK):
            raise RuntimeError(f"Missing executable: {path}")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], timeout=30)
    signature = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=4", str(app)],
                               capture_output=True, text=True, timeout=15)
    if signature.returncode or "Authority=Apple Development:" not in signature.stderr:
        raise RuntimeError("Expected a signed Apple Development identity; refusing ad-hoc bundle")


def config_hashes() -> dict[str, str | None]:
    def digest(filename: str) -> str | None:
        p = STATE / filename
        return hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else None
    return {"config": digest("config.json"), "control": digest("control.token")}


def control_status(timeout: float = 1.5) -> dict | None:
    token_file = STATE / "control.token"
    if not token_file.is_file():
        return None
    token = token_file.read_text(encoding="utf-8").strip()
    req = urllib.request.Request(
        "http://127.0.0.1:8765/control/status",
        headers={"x-relayos-control-token": token})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return json.load(response) if response.status == 200 else None
    except (OSError, ValueError, urllib.error.HTTPError):
        return None


def port_is_open(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.8):
            return True
    except OSError:
        return False


def app_pids() -> set[int]:
    output = run(["/bin/ps", "-axo", "pid=,command="], timeout=10)
    executable = str(INSTALLED / EXEC_REL)
    pids: set[int] = set()
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2:
            continue
        try:
            pid = int(fields[0])
        except ValueError:
            continue
        # Exclude shell commands, test binaries, and staged applications.
        command = fields[1]
        if command == executable or command.startswith(executable + " "):
            pids.add(pid)
    return pids


def write_status(phase: str, **data: object) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    document = {"phase": phase, "timestamp": dt.datetime.now().isoformat(), **data}
    temporary = STATUS.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    temporary.replace(STATUS)
    print("HANDOVER", phase, flush=True)


def wait_healthy(expected: dict | None, baseline_hashes: dict, timeout: int = 65) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        status = control_status()
        if status is not None and port_is_open(4040):
            if config_hashes() != baseline_hashes:
                raise RuntimeError("Saved config/control token changed during handover")
            if expected:
                for key in ("setup_complete", "active_transport", "emergency_stop"):
                    if status.get(key) != expected.get(key):
                        raise RuntimeError(f"Unexpected {key}: {status.get(key)!r}")
            return status
        time.sleep(1)
    raise RuntimeError("New app did not restore authenticated MCP + ngrok health")


def stop_old_app() -> None:
    pids = app_pids()
    if pids:
        # Ask the macOS app to shut down its owned MCP/ngrok subprocesses.
        subprocess.run(
            ["/usr/bin/osascript", "-e",
             'tell application id "pro.micorp.relayos" to quit'],
            cwd=ROOT, timeout=12, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
    deadline = time.monotonic() + 18
    while time.monotonic() < deadline:
        if not app_pids() and not port_is_open(8765):
            return
        time.sleep(0.5)
    remaining = app_pids()
    for pid in remaining:
        os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if not app_pids() and not port_is_open(8765):
            return
        time.sleep(0.5)
    raise RuntimeError("Previous RelayOS app/helper did not stop cleanly; installation aborted")


def open_installed() -> None:
    run(["/usr/bin/open", "-a", str(INSTALLED)], timeout=12)


def handover(temporary: Path, backup: Path, expected: dict | None,
             baseline_hashes: dict) -> None:
    # Let the command job return its response before stopping its own MCP host.
    time.sleep(5)
    replaced = False
    try:
        write_status("stopping-old", backup=str(backup), log=str(LOG))
        stop_old_app()
        if not INSTALLED.is_dir():
            raise RuntimeError("Installed app disappeared before backup rename")
        if backup.exists():
            raise RuntimeError(f"Backup path already exists: {backup}")
        INSTALLED.rename(backup)
        try:
            temporary.rename(INSTALLED)
        except Exception:
            backup.rename(INSTALLED)
            raise
        replaced = True
        check_bundle(INSTALLED)
        write_status("launching-new", backup=str(backup))
        open_installed()
        result = wait_healthy(expected, baseline_hashes)
        write_status("success", backup=str(backup),
                     setup_complete=result.get("setup_complete"),
                     active_transport=result.get("active_transport"),
                     emergency_stop=result.get("emergency_stop"),
                     mcp_port=8765, ngrok_port=4040)
    except Exception as exc:
        print(f"HANDOVER FAILED: {exc}", flush=True)
        try:
            if replaced:
                # Stop only the newly installed app before restoring.
                try:
                    stop_old_app()
                except Exception:
                    pass
                failed = backup.with_name(backup.name + ".failed-new")
                if INSTALLED.exists():
                    INSTALLED.rename(failed)
                backup.rename(INSTALLED)
                open_installed()
                # Keep the restored previous installation even if its network
                # health is temporarily unavailable.
                write_status("rolled-back", error=str(exc), restored=str(INSTALLED),
                             failed_new=str(failed))
            else:
                if INSTALLED.exists() and not app_pids():
                    open_installed()
                write_status("failed-before-replacement", error=str(exc),
                             current_app=str(INSTALLED))
        except Exception as rollback_error:
            write_status("rollback-error", error=str(exc),
                         rollback_error=str(rollback_error),
                         backup=str(backup), installed=str(INSTALLED))
        raise


def prepare() -> None:
    if not STAGED.is_dir() or not INSTALLED.is_dir():
        raise RuntimeError("Staged or installed app missing")
    if not os.access(INSTALLED.parent, os.W_OK):
        raise RuntimeError("/Applications is not writable by the current user")
    check_bundle(STAGED)
    baseline_hashes = config_hashes()
    expected = control_status()
    if expected is None:
        raise RuntimeError("Cannot authenticate existing MCP status; aborting")
    if not expected.get("setup_complete"):
        raise RuntimeError("Installed app onboarding is incomplete; aborting")
    print("Signed bundle and authenticated existing MCP verified", flush=True)

    for smoke in ("smoke_packaged_mcp.py", "smoke_mcp_restart.py"):
        output = run([sys.executable, str(ROOT / "scripts" / smoke), str(STAGED)], timeout=95)
        print(output.strip(), flush=True)

    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = INSTALLED.with_name(f"RelayOS.app.pre-update-{stamp}")
    temporary = INSTALLED.with_name(f".RelayOS.staged-{stamp}.app")
    if temporary.exists() or backup.exists():
        raise RuntimeError("Backup or temporary app path collision")
    # Same-volume staging allows a quick rename instead of replacing files in
    # the running app. Avoid deleting any user app/state data.
    run(["/usr/bin/ditto", str(STAGED), str(temporary)], timeout=120)
    check_bundle(temporary)
    write_status("prepared", backup=str(backup), staged=str(temporary),
                 log=str(LOG), production_port=8765)
    manifest = LOG_DIR / "handover-private.json"
    manifest.write_text(json.dumps({
        "temporary": str(temporary), "backup": str(backup),
        "expected": {key: expected.get(key)
                     for key in ("setup_complete", "active_transport", "emergency_stop")},
        "baseline_hashes": baseline_hashes
    }), encoding="utf-8")
    manifest.chmod(0o600)
    child_args = [sys.executable, str(Path(__file__).resolve()), "--handover",
                  str(manifest)]
    with LOG.open("a", encoding="utf-8") as log:
        child = subprocess.Popen(
            child_args, cwd=ROOT, stdin=subprocess.DEVNULL,
            stdout=log, stderr=subprocess.STDOUT,
            start_new_session=True, close_fds=True)
    write_status("handover-dispatched", pid=child.pid,
                 backup=str(backup), log=str(LOG))
    print(f"Detached handover process {child.pid}; result: {STATUS}", flush=True)


def main() -> None:
    if len(sys.argv) == 1:
        prepare()
    elif len(sys.argv) == 3 and sys.argv[1] == "--handover":
        manifest = Path(sys.argv[2])
        try:
            settings = json.loads(manifest.read_text(encoding="utf-8"))
            handover(Path(settings["temporary"]), Path(settings["backup"]),
                     settings["expected"], settings["baseline_hashes"])
        finally:
            manifest.unlink(missing_ok=True)
    else:
        raise SystemExit("Usage: deploy_verified_relayos.py")


if __name__ == "__main__":
    main()
