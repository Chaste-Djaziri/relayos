"""PyInstaller entrypoint for RelayOS approval and permission commands."""

import sys

from laptop_bridge.approvals import main


if __name__ == "__main__":
    # The Swift development path invokes `python -m laptop_bridge.approvals`.
    # Accept that same argv shape when the bundled executable is used.
    if sys.argv[1:3] == ["-m", "laptop_bridge.approvals"]:
        del sys.argv[1:3]
    main()
