"""Authenticated loopback control API for native companions.

This API is intentionally separate from the public MCP transport. It is bound
to loopback by the server and requires a per-installation bearer token.
"""
import json
import secrets
import os
import subprocess
import threading
import time
import urllib.request
from pathlib import Path

from starlette.requests import Request
from starlette.responses import JSONResponse

from . import keychain, state
from . import ngrok
from .config import CONFIG_FILE, STATE_DIR, load_config, save_config

TOKEN_FILE = STATE_DIR / "control.token"
_ngrok_process = None
_ngrok_lock = threading.Lock()


def control_token():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    if not TOKEN_FILE.exists():
        TOKEN_FILE.write_text(secrets.token_urlsafe(32), encoding="ascii")
        try:
            TOKEN_FILE.chmod(0o600)
        except OSError:
            pass
    return TOKEN_FILE.read_text(encoding="ascii").strip()


def authorized(request: Request):
    return secrets.compare_digest(request.headers.get("x-relayos-control-token", ""), control_token())


async def json_body(request):
    try:
        value = await request.json()
    except Exception:
        value = {}
    return value if isinstance(value, dict) else {}


def status():
    config = load_config()
    return {
        "setup_complete": bool(config.get("setup_complete")),
        "public_base_url": config.get("public_base_url", ""),
        "mcp_endpoint": f"{config.get('public_base_url', '').rstrip('/')}/mcp" if config.get("public_base_url") else "",
        "active_transport": config.get("active_transport", "ngrok"),
        "ngrok": config.get("ngrok", {}),
        "capabilities": config.get("capabilities", {}),
        "emergency_stop": state.emergency_stop(),
        "pending_approvals": len(state.pending_requests()) + len(state.pending_oauth_authorizations()),
        "connections": state.active_oauth_grants(),
        "permissions": state.saved_command_grants(),
    }


def launch_ngrok():
    global _ngrok_process
    with _ngrok_lock:
        if _ngrok_process is not None and _ngrok_process.poll() is None:
            return {"started": False, "running": True}
        config = load_config()
        if config.get("active_transport") != "ngrok" or not config.get("ngrok", {}).get("enabled"):
            return {"started": False, "running": False, "reason": "ngrok is not configured"}
        token = keychain.get_secret("ngrok_authtoken") or ""
        spec = ngrok.process_spec(config.get("ngrok", {}).get("domain", ""), token)
        env = os.environ.copy()
        env.update(spec["environment"])
        _ngrok_process = subprocess.Popen(
            [spec["executable"], *spec["arguments"]], env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        threading.Thread(target=_watch_ngrok, args=(_ngrok_process,), daemon=True).start()
        threading.Thread(target=_inspect_ngrok, daemon=True).start()
        return {"started": True, "running": True}


def _watch_ngrok(process):
    for line in process.stdout or ():
        endpoint = ngrok.extract_endpoint(line)
        if endpoint:
            config = load_config()
            config["public_base_url"] = endpoint
            config.setdefault("ngrok", {})["domain"] = endpoint.removeprefix("https://")
            save_config(config)


def _inspect_ngrok():
    for _ in range(30):
        time.sleep(1)
        try:
            with urllib.request.urlopen("http://127.0.0.1:4040/api/tunnels", timeout=1) as response:
                payload = json.loads(response.read().decode("utf-8"))
            endpoint = next((item.get("public_url") for item in payload.get("tunnels", []) if item.get("public_url", "").startswith("https://")), None)
            if endpoint:
                config = load_config()
                config["public_base_url"] = endpoint.rstrip("/")
                config.setdefault("ngrok", {})["domain"] = endpoint.removeprefix("https://").rstrip("/")
                save_config(config)
                return
        except Exception:
            continue


async def handle(request: Request):
    if not authorized(request):
        return JSONResponse({"error": "Unauthorized"}, status_code=401)
    path = request.url.path
    method = request.method
    if method == "GET" and path == "/control/status":
        return JSONResponse(status())
    if method == "GET" and path == "/control/connections":
        return JSONResponse({"connections": state.active_oauth_grants()})
    if method == "GET" and path == "/control/permissions":
        return JSONResponse({"permissions": state.saved_command_grants()})
    if method == "GET" and path == "/control/pending-approvals":
        return JSONResponse({"oauth": state.pending_oauth_authorizations(), "actions": state.pending_requests()})
    if method == "GET" and path == "/control/activity":
        return JSONResponse({"activity": state.recent_history(100)})
    if method == "POST" and path == "/control/decide":
        payload = await json_body(request)
        request_id = str(payload.get("request_id", ""))
        approved = bool(payload.get("approved", False))
        oauth = next((item for item in state.pending_oauth_authorizations() if item["request_id"] == request_id), None)
        if oauth:
            state.decide_oauth_authorization(request_id, approved)
            return JSONResponse({"decided": True, "approved": approved})
        pending = next((item for item in state.pending_requests() if item["request_id"] == request_id), None)
        if pending:
            (state.approve if approved else state.deny)(request_id)
            return JSONResponse({"decided": True, "approved": approved})
        return JSONResponse({"error": "Approval not found or expired"}, status_code=404)
    if method == "POST" and path in {"/control/services/start", "/control/services/stop", "/control/services/restart"}:
        # The native supervisor owns child-process lifecycle. These routes are
        # intentionally acknowledgement endpoints for the shared contract;
        # the Python server itself remains alive on its MCP process.
        action = path.rsplit("/", 1)[-1]
        result = launch_ngrok() if action in {"start", "restart"} else {"started": False}
        return JSONResponse({"accepted": True, "action": action, **result})
    if method == "POST" and path == "/control/emergency-stop":
        payload = await json_body(request)
        state.set_emergency_stop(bool(payload.get("enabled", True)))
        return JSONResponse({"emergency_stop": state.emergency_stop()})
    if method == "POST" and path == "/control/setup/capabilities":
        payload = await json_body(request)
        config = load_config()
        config["capabilities"] = {
            "system_status": True,
            "screen_guidance": bool(payload.get("screen_guidance", False)),
            "project_tools": bool(payload.get("project_tools", False)),
        }
        save_config(config)
        return JSONResponse({"capabilities": config["capabilities"]})
    if method == "POST" and path == "/control/setup/ngrok":
        payload = await json_body(request)
        token = str(payload.get("token", "")).strip()
        domain = str(payload.get("domain", "")).strip().removeprefix("https://").strip("/")
        if not token:
            return JSONResponse({"error": "ngrok token is required"}, status_code=400)
        keychain.set_secret("ngrok_authtoken", token)
        config = load_config()
        config.update({"active_transport": "ngrok", "setup_complete": True,
                       "public_base_url": f"https://{domain}" if domain else "",
                       "ngrok": {"enabled": True, "domain": domain, "region": "", "config_path": "", "agent_version": ""}})
        save_config(config)
        return JSONResponse({"configured": True, "domain": domain})
    return JSONResponse({"error": "Not found"}, status_code=404)
