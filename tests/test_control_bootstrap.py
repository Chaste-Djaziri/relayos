# Path: tests/test_control_bootstrap.py
"""The native companion's authenticated health check must work on first launch."""
from laptop_bridge import server


def test_server_initializes_local_control_token_before_binding_listener(monkeypatch):
    sequence = []
    monkeypatch.setattr(server.control, "control_token", lambda: sequence.append("control-token"))
    monkeypatch.setattr(server.state, "interrupt_orphan_command_jobs", lambda: None)
    monkeypatch.setattr(
        server, "load_config",
        lambda: {"capabilities": {"screen_guidance": True, "project_tools": True}},
    )
    monkeypatch.setattr(server, "public_base_url", lambda _config: None)
    monkeypatch.setattr(server.mcp, "run", lambda **_kwargs: sequence.append("listener"))
    server.main()
    assert sequence == ["control-token", "listener"]
