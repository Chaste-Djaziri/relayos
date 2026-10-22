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
