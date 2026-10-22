# Path: tests/test_access.py
from pathlib import Path
import pytest
from laptop_bridge.config import authorized_path

def test_allowed(tmp_path):
    folder = tmp_path / "safe"
    folder.mkdir()
    file = folder / "test.txt"
    file.write_text("hi")
    assert authorized_path(str(file), {"allowed_folders": [str(folder)]}) == file.resolve()

def test_rejected(tmp_path):
    folder = tmp_path / "safe"
    folder.mkdir()
    other = tmp_path / "private.txt"
    other.write_text("secret")
    with pytest.raises(PermissionError):
        authorized_path(str(other), {"allowed_folders": [str(folder)]})


def test_list_processes():
    from laptop_bridge.server import list_processes
    procs = list_processes(limit=10, sort_by="cpu")
    assert isinstance(procs, list)
    assert len(procs) > 0
    first = procs[0]
    assert "pid" in first
    assert "name" in first
    assert "cpu_percent" in first
    assert "memory_percent" in first
    assert "memory_mb" in first

