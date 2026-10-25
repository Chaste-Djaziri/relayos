import json

from laptop_bridge import config


def test_migrate_state_excludes_secret_and_requires_windows_setup(tmp_path, monkeypatch):
    source = tmp_path / "mac-state"
    source.mkdir()
    (source / "config.json").write_text(json.dumps({
        "public_base_url": "https://bridge.ngrok.app",
        "setup_complete": True,
        "ngrok_authtoken": "do-not-copy",
        "ngrok": {"enabled": True, "domain": "bridge.ngrok.app"},
    }), encoding="utf-8")
    (source / "state.sqlite3").write_bytes(b"sqlite-placeholder")
    target = tmp_path / "target"
    monkeypatch.setattr(config, "STATE_DIR", target)
    monkeypatch.setattr(config, "CONFIG_FILE", target / "config.json")
    monkeypatch.setattr(config, "DATABASE_FILE", target / "state.sqlite3")

    result = config.migrate_state(source)
    imported = json.loads((target / "config.json").read_text(encoding="utf-8"))
    assert result["requires_ngrok_setup"] is True
    assert imported["setup_complete"] is False
    assert "ngrok_authtoken" not in imported
    assert imported["ngrok"]["enabled"] is False
