def test_system_status_returns_partial_data_when_sensor_fails(monkeypatch):
    from laptop_bridge import server

    monkeypatch.setattr(server.psutil, "cpu_percent", lambda interval=0.1: (_ for _ in ()).throw(RuntimeError("unavailable")))
    monkeypatch.setattr(server.psutil, "virtual_memory", lambda: (_ for _ in ()).throw(RuntimeError("unavailable")))
    monkeypatch.setattr(server.psutil, "sensors_battery", lambda: (_ for _ in ()).throw(RuntimeError("unavailable")))
    result = server.system_status()
    assert result["cpu_percent"] is None
    assert result["ram_used_percent"] is None
    assert result["battery_percent"] is None
