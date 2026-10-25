# Path: src/laptop_bridge/config.py
import json
import os
import shutil
from pathlib import Path

STATE_DIR = Path(os.getenv("LAPTOP_BRIDGE_STATE", str(Path.home() / ".laptop-bridge"))).expanduser().resolve()
CONFIG_FILE = STATE_DIR / "config.json"
DATABASE_FILE = STATE_DIR / "state.sqlite3"

DEFAULT = {
    # No directory is implicitly authorized. Users grant individual roots
    # through a confirmed project session or explicitly configure them.
    "allowed_folders": [],
    "allowed_apps": {},
    "allowed_commands": {},
    "max_read_bytes": 65536,
    # A public HTTPS origin is opt-in and is used for OAuth metadata.
    "public_base_url": "",
    "active_transport": "ngrok",
    "setup_complete": False,
    "capabilities": {
        "system_status": True,
        "screen_guidance": False,
        "project_tools": False,
    },
    "cloudflare": {
        "zone_id": "",
        "hostname": "",
        "tunnel_id": "",
        "config_path": "",
    },
    "ngrok": {
        "enabled": False,
        "domain": "",
        "region": "",
        "config_path": "",
        "agent_version": "",
    },
    "connection_modes": {
        "chatgpt_public": True,
        "gemini_public": True,
        "openai_secure_tunnel": False,
    },
}

def load_config():
    STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not CONFIG_FILE.exists():
        CONFIG_FILE.write_text(json.dumps(DEFAULT, indent=2), encoding="utf-8")
        try:
            CONFIG_FILE.chmod(0o600)
        except OSError:
            pass
    config = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
    # Existing installations predate public-endpoint support.  Keep their
    # behavior unchanged until they opt in by setting this value.
    config.setdefault("public_base_url", "")
    config.setdefault("active_transport", "ngrok" if config.get("ngrok", {}).get("domain") else "cloudflare")
    # A configured public endpoint is sufficient to treat older installs as
    # onboarded; users can still reopen the setup wizard from the companion.
    config.setdefault("setup_complete", bool(config.get("public_base_url")))
    config.setdefault("capabilities", dict(DEFAULT["capabilities"]))
    config.setdefault("cloudflare", dict(DEFAULT["cloudflare"]))
    config.setdefault("ngrok", dict(DEFAULT["ngrok"]))
    config.setdefault("connection_modes", dict(DEFAULT["connection_modes"]))
    return config


def save_config(config):
    """Persist non-secret setup state with restrictive permissions."""
    STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    CONFIG_FILE.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
    try:
        CONFIG_FILE.chmod(0o600)
    except OSError:
        pass
    return config


def migrate_state(source):
    """Explicitly import non-secret state from another installation.

    Only config.json and state.sqlite3 are copied. Keychain/Credential Manager
    secrets are deliberately excluded and must be entered on Windows once.
    """
    source_dir = Path(source).expanduser().resolve(strict=True)
    if not source_dir.is_dir():
        raise ValueError("Migration source must be a directory")
    source_config = source_dir / "config.json"
    source_db = source_dir / "state.sqlite3"
    if not source_config.is_file():
        raise ValueError("Migration source does not contain config.json")
    imported = json.loads(source_config.read_text(encoding="utf-8"))
    if not isinstance(imported, dict):
        raise ValueError("config.json must contain an object")
    # Never import a secret or mark setup complete without a Windows secret.
    imported.pop("ngrok_authtoken", None)
    imported["setup_complete"] = False
    imported.setdefault("ngrok", {}).update({"enabled": False})
    save_config(imported)
    copied = [str(CONFIG_FILE)]
    if source_db.is_file():
        shutil.copy2(source_db, DATABASE_FILE)
        copied.append(str(DATABASE_FILE))
    return {"source": str(source_dir), "copied": copied, "requires_ngrok_setup": True}


def update_config(**changes):
    config = load_config()
    config.update(changes)
    return save_config(config)


def public_base_url(config=None):
    """Return the configured public HTTPS origin without a trailing slash."""
    value = (config or load_config()).get("public_base_url", "").strip().rstrip("/")
    if not value:
        return None
    if not value.startswith("https://") or "/" in value.removeprefix("https://"):
        raise ValueError("public_base_url must be an HTTPS origin without a path")
    return value

def authorized_path(raw, config):
    path = Path(raw).expanduser().resolve(strict=True)
    roots = [Path(p).expanduser().resolve(strict=True) for p in config["allowed_folders"]]
    granted = False
    try:
        from .state import folder_granted
        granted = folder_granted(path)
    except Exception:
        granted = False
    if not granted and not any(path == root or root in path.parents for root in roots):
        raise PermissionError("Path outside authorized folders")
    return path
