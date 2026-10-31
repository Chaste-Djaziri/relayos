# Path: scripts/smoke_packaged_mcp.py
"""Smoke-test a packaged RelayOS MCP helper without touching the live service.

Runs the bundled server on a dynamically allocated loopback port with isolated
temporary state. Checks that unauthenticated control traffic is rejected and
that the native companion's token-authenticated health contract works.
"""
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


def available_loopback_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def smoke_test(app):
    executable = app / "Contents" / "Resources" / "Runtime" / "RelayOSMCPServer"
    if not executable.is_file():
        raise FileNotFoundError(f"No packaged MCP server at {executable}")
    with tempfile.TemporaryDirectory(prefix="relayos-smoke-") as temp:
        state = Path(temp) / "state"
        port = available_loopback_port()
        environment = os.environ.copy()
        environment.update({
            "LAPTOP_BRIDGE_STATE": str(state),
            "LAPTOP_BRIDGE_MCP_PORT": str(port),
        })
        # The subprocess is isolated in a process group, so cleanup never
        # sends signals to the existing RelayOS app, tunnel or MCP server.
        process = subprocess.Popen(
            [str(executable)],
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
        try:
            endpoint = f"http://127.0.0.1:{port}/control/status"
            deadline = time.monotonic() + 20
            token_file = state / "control.token"
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError("Packaged MCP helper exited during startup")
                if token_file.is_file():
                    try:
                        urllib.request.urlopen(endpoint, timeout=0.5)
                    except urllib.error.HTTPError as response:
                        if response.code == 401:
                            break
                    except (OSError, TimeoutError):
                        pass
                time.sleep(0.25)
            else:
                raise TimeoutError("Packaged MCP helper did not expose its control endpoint")
            token = token_file.read_text(encoding="ascii").strip()
            request = urllib.request.Request(
                endpoint, headers={"x-relayos-control-token": token}
            )
            with urllib.request.urlopen(request, timeout=3) as response:
                if response.status != 200:
                    raise RuntimeError("Authenticated control endpoint returned non-200")
                payload = json.load(response)
            for key in ("setup_complete", "active_transport", "pending_approvals", "emergency_stop", "capabilities"):
                if key not in payload:
                    raise AssertionError(f"Missing status field: {key}")
            print("PASS: packaged MCP server started on isolated loopback port")
            print("PASS: anonymous control request rejected with HTTP 401")
            print("PASS: control-token authenticated status returned HTTP 200")
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=3)


if __name__ == "__main__":
    app = Path(sys.argv[1] if len(sys.argv) > 1 else "dist/relayos-sprint01/RelayOS.app").resolve()
    smoke_test(app)
