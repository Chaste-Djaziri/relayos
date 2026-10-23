"""ngrok agent helpers for stable per-user MCP endpoints."""
import os
import re
import shutil
from pathlib import Path

DOMAIN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$")


class NgrokError(RuntimeError):
    pass


def validate_domain(value):
    domain = value.strip().lower().removeprefix("https://").removeprefix("http://").rstrip("/")
    if not DOMAIN_RE.fullmatch(domain) or "/" in domain or ":" in domain:
        raise NgrokError("Enter a reserved ngrok domain without a path, for example bridge.ngrok.app")
    return domain


def find_executable():
    candidates = [
        Path(__file__).resolve().parents[2] / "resources" / "ngrok",
        Path("/opt/homebrew/bin/ngrok"),
        Path("/usr/local/bin/ngrok"),
    ]
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return shutil.which("ngrok")


def endpoint_url(domain):
    return f"https://{validate_domain(domain)}"


def process_spec(domain, token, executable=None, upstream="127.0.0.1:8765"):
    """Return a safe process specification; the token is environment-only."""
    if not token.strip():
        raise NgrokError("An ngrok authtoken is required")
    executable = executable or find_executable()
    if not executable:
        raise NgrokError("ngrok was not found. Install it from ngrok.com/download")
    return {
        "executable": executable,
        "arguments": ["http", upstream, "--domain", validate_domain(domain)],
        "environment": {"NGROK_AUTHTOKEN": token},
        "endpoint": endpoint_url(domain),
    }
