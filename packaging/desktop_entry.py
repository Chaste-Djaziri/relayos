import sys

from laptop_bridge.desktop import main
from laptop_bridge.server import main as server_main


if __name__ == "__main__":
    server_main() if "--server" in sys.argv[1:] else main()
