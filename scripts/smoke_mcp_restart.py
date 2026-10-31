# Path: scripts/smoke_mcp_restart.py
"""Exercise two isolated packaged MCP launches after a forced child crash.

This script never binds the production port or signals an existing app process.
It verifies that the packaged server releases its port and can rebind using the
same isolated state and control token. Swift unit tests cover supervisor retry.
"""
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

from smoke_packaged_mcp import available_loopback_port


def verify_ready(process, endpoint, token_file):
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"Packaged MCP helper died: {process.returncode}")
        if token_file.is_file():
            token = token_file.read_text(encoding="ascii").strip()
            request = urllib.request.Request(endpoint, headers={"x-relayos-control-token": token})
            try:
                with urllib.request.urlopen(request, timeout=0.8) as response:
                    if response.status == 200:
                        data = json.load(response)
                        if "capabilities" in data and "emergency_stop" in data:
                            return token
            except (urllib.error.URLError, TimeoutError, ConnectionError, ValueError):
                pass
        time.sleep(0.25)
    raise TimeoutError("Isolated helper did not become healthy")


def smoke_recovery(app):
    executable = app / "Contents/Resources/Runtime/RelayOSMCPServer"
    if not executable.is_file():
        raise FileNotFoundError(executable)
    with tempfile.TemporaryDirectory(prefix="relayos-recovery-") as temporary:
        state = Path(temporary) / "state"
        port = available_loopback_port()
        endpoint = f"http://127.0.0.1:{port}/control/status"
        env = dict(os.environ, LAPTOP_BRIDGE_STATE=str(state), LAPTOP_BRIDGE_MCP_PORT=str(port))
        token_before = None
        for run in range(2):
            process = subprocess.Popen(
                [str(executable)], env=env, start_new_session=True,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            try:
                token = verify_ready(process, endpoint, state / "control.token")
                if run == 0:
                    token_before = token
                    print("PASS: first isolated MCP helper authenticated")
                else:
                    assert token == token_before, "Local control token changed across restart"
                    print("PASS: replacement helper rebound same isolated port with existing token")
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL if run == 0 else signal.SIGTERM)
                try:
                    process.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=4)
        print("PASS: isolated crash/restart completed without touching live port 8765")


if __name__ == "__main__":
    smoke_recovery(Path(sys.argv[1] if len(sys.argv) > 1 else "dist/RelayOS.app").resolve())
