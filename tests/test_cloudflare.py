from laptop_bridge import cloudflare


def test_find_zone_uses_longest_matching_suffix(monkeypatch):
    calls = []
    def fake(token, method, path, payload=None):
        calls.append(path)
        if "name=example.com" in path:
            return [{"id": "zone-1", "account": {"id": "acct-1"}}]
        return []
    monkeypatch.setattr(cloudflare, "_request", fake)
    assert cloudflare.find_zone("secret", "mcp.example.com")["id"] == "zone-1"
    assert any("name=example.com" in path for path in calls)


def test_provision_builds_tunnel_and_dns_requests(monkeypatch):
    calls = []
    def fake(token, method, path, payload=None):
        calls.append((method, path, payload))
        if path.startswith("/zones?"):
            return [{"id": "zone-1", "account": {"id": "acct-1"}}]
        if path == "/accounts/acct-1/cfd_tunnels":
            return {"id": "tun-1", "name": "Laptop Bridge"}
        if path.endswith("/token"):
            return "tunnel-token"
        if "/dns_records" in path:
            return []
        return {}
    monkeypatch.setattr(cloudflare, "_request", fake)
    result = cloudflare.provision("secret", "mcp.example.com")
    assert result["hostname"] == "mcp.example.com"
    assert result["tunnel_token"] == "tunnel-token"
    assert any(method == "PUT" and "/configurations" in path for method, path, _ in calls)
    assert any(method == "POST" and "/dns_records" in path for method, path, _ in calls)
