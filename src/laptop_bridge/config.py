# Path: src/laptop_bridge/config.py
import json
import os
from pathlib import Path

STATE_DIR = Path(os.getenv("LAPTOP_BRIDGE_STATE", str(Path.home() / ".laptop-bridge"))).expanduser().resolve()
CONFIG_FILE = STATE_DIR / "config.json"
PENDING_FILE = STATE_DIR / "requests.json"

DEFAULT = {
    "allowed_folders": [str(Path.home() / "Documents")],
    "allowed_apps": {},
    "allowed_commands": {},
    "max_read_bytes": 65536,
}

def load_config():
    STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not CONFIG_FILE.exists():
        CONFIG_FILE.write_text(json.dumps(DEFAULT, indent=2), encoding="utf-8")
        try:
            CONFIG_FILE.chmod(0o600)
        except OSError:
            pass
    return json.loads(CONFIG_FILE.read_text(encoding="utf-8"))

def authorized_path(raw, config):
    path = Path(raw).expanduser().resolve(strict=True)
    roots = [Path(p).expanduser().resolve(strict=True) for p in config["allowed_folders"]]
    if not any(path == root or root in path.parents for root in roots):
        raise PermissionError("Path outside authorized folders")
    return path
