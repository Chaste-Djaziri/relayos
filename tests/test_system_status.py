def test_system_status_returns_partial_data_when_sensor_fails(monkeypatch):
    from laptop_bridge import server

    monkeypatch.setattr(server.psutil, "cpu_percent", lambda interval=0.1: (_ for _ in ()).throw(RuntimeError("unavailable")))
    monkeypatch.setattr(server.psutil, "virtual_memory", lambda: (_ for _ in ()).throw(RuntimeError("unavailable")))
    monkeypatch.setattr(server.psutil, "sensors_battery", lambda: (_ for _ in ()).throw(RuntimeError("unavailable")))
    monkeypatch.setattr(server.subprocess, "run", lambda *args, **kwargs: (_ for _ in ()).throw(OSError("unavailable")))
    result = server.system_status()
    assert result["cpu_percent"] is None
    assert result["ram_used_percent"] is None
    assert result["battery_percent"] is None


def test_system_status_reads_macos_battery_from_pmset(monkeypatch):
    from laptop_bridge import server

    class Completed:
        stdout = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=123)\t81%; charging; 0:00 remaining present: true\n"

    monkeypatch.setattr(server.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(server.subprocess, "run", lambda *args, **kwargs: Completed())
    result = server.system_status()
    assert result["battery_percent"] == 81
    assert result["battery_charging"] is True


def test_system_status_reads_windows_battery_from_psutil(monkeypatch):
    from laptop_bridge import server

    battery = type("Battery", (), {"percent": 64.5, "power_plugged": False})()
    monkeypatch.setattr(server.platform, "system", lambda: "Windows")
    monkeypatch.setattr(server.psutil, "sensors_battery", lambda: battery)

    result = server.system_status()

    assert result["battery_percent"] == 64.5
    assert result["battery_charging"] is False


def test_windows_command_path_includes_common_gui_tool_locations(monkeypatch):
    from laptop_bridge import server

    monkeypatch.setattr(server, "_is_windows", lambda: True)
    monkeypatch.setenv("LOCALAPPDATA", r"C:\\Users\\Test\\AppData\\Local")
    monkeypatch.setenv("ProgramFiles", r"C:\\Program Files")

    value = server._coding_command_path()

    assert "nodejs" in value
    assert "Git" in value
