# Path: src/laptop_bridge/config.py
import json
import os
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
    # A public HTTPS origin is opt-in.  It is used for OAuth metadata and the
    # Streamable HTTP resource identifier when a relay (such as Cloudflare
    # Tunnel) forwards requests to this loopback-only server.
    "public_base_url": "",
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
    return config


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
    if not any(path == root or root in path.parents for root in roots):
        raise PermissionError("Path outside authorized folders")
    return path
