"""Minimal Cloudflare API client used by first-run provisioning."""
import base64
import json
import secrets
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://api.cloudflare.com/client/v4"


class CloudflareError(RuntimeError):
    pass


def _request(token, method, path, payload=None):
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        API + path, data=body, method=method,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            result = json.loads(response.read().decode("utf-8"))
    except (urllib.error.HTTPError, urllib.error.URLError, ValueError) as error:
        raise CloudflareError(f"Cloudflare request failed: {error}") from error
    if not result.get("success"):
        messages = "; ".join(item.get("message", "Unknown error") for item in result.get("errors", []))
        raise CloudflareError(messages or "Cloudflare rejected the request")
    return result.get("result")


def find_zone(token, hostname):
    labels = hostname.rstrip(".").split(".")
    for index in range(len(labels) - 1):
        zone_name = ".".join(labels[index:])
        result = _request(token, "GET", "/zones?" + urllib.parse.urlencode({"name": zone_name, "status": "active"}))
        if result:
            return result[0]
    raise CloudflareError("No active Cloudflare zone matches that hostname")


def provision(token, hostname, tunnel_name="Laptop Bridge"):
    """Create a named tunnel, its ingress, and a proxied CNAME record."""
    hostname = hostname.strip().lower().rstrip(".")
    zone = find_zone(token, hostname)
    secret = base64.b64encode(secrets.token_bytes(32)).decode("ascii")
    tunnel = _request(token, "POST", f"/accounts/{zone['account']['id']}/cfd_tunnels", {"name": tunnel_name, "tunnel_secret": secret})
    tunnel_id = tunnel["id"]
    _request(token, "PUT", f"/accounts/{zone['account']['id']}/cfd_tunnels/{tunnel_id}/configurations", {"config": {"ingress": [{"hostname": hostname, "service": "http://127.0.0.1:8765"}, {"service": "http_status:404"}]}})
    existing = _request(token, "GET", f"/zones/{zone['id']}/dns_records?" + urllib.parse.urlencode({"type": "CNAME", "name": hostname}))
    record = {"type": "CNAME", "name": hostname, "content": f"{tunnel_id}.cfargotunnel.com", "ttl": 1, "proxied": True}
    if existing:
        _request(token, "PUT", f"/zones/{zone['id']}/dns_records/{existing[0]['id']}", record)
    else:
        _request(token, "POST", f"/zones/{zone['id']}/dns_records", record)
    tunnel_token = _request(token, "GET", f"/accounts/{zone['account']['id']}/cfd_tunnels/{tunnel_id}/token")
    return {"zone_id": zone["id"], "account_id": zone["account"]["id"], "tunnel_id": tunnel_id, "hostname": hostname, "tunnel_token": tunnel_token}
