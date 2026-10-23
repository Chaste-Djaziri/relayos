#!/bin/sh
set -eu

# Build a Finder-launchable RelayOS.app. The app owns its child processes and
# does not require a terminal, repository checkout, or active virtualenv after
# installation.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

DIST_DIR=${DIST_DIR:-"$ROOT_DIR/dist"}
APP_NAME="RelayOS"
APP_PATH="$DIST_DIR/$APP_NAME.app"
STAGE_DIR="$DIST_DIR/.relayos-stage"
PYTHON_BIN=${PYTHON_BIN:-"$ROOT_DIR/.venv/bin/python"}
SIGNING_IDENTITY=${RELAYOS_SIGNING_IDENTITY:-${LAPTOP_BRIDGE_SIGNING_IDENTITY:-}}

if [ ! -x "$PYTHON_BIN" ]; then
  PYTHON_BIN=$(command -v python3 || true)
fi
if [ -z "$PYTHON_BIN" ] || [ ! -x "$PYTHON_BIN" ]; then
  echo "Python 3 is required to build the embedded MCP helper." >&2
  exit 1
fi

command -v swift >/dev/null 2>&1 || { echo "Swift is required." >&2; exit 1; }
command -v pyinstaller >/dev/null 2>&1 || "$PYTHON_BIN" -m PyInstaller --version >/dev/null 2>&1 || {
  echo "PyInstaller is required. Install development dependencies first." >&2
  exit 1
}

rm -rf "$STAGE_DIR" "$APP_PATH"
mkdir -p "$STAGE_DIR/runtime" "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
mkdir -p "$APP_PATH/Contents/Resources/Runtime"

swift build -c release --package-path Native/LaptopBridgeApp
cp Native/LaptopBridgeApp/.build/arm64-apple-macosx/release/LaptopBridgeApp "$APP_PATH/Contents/MacOS/RelayOS" 2>/dev/null || \
  cp Native/LaptopBridgeApp/.build/out/Products/Release/LaptopBridgeApp "$APP_PATH/Contents/MacOS/RelayOS"

# Build only the MCP server entrypoint. PyInstaller follows the server's
# imports directly; collecting the entire optional MCP CLI would require the
# unrelated `typer` extra and would make the desktop bundle unnecessarily
# large.
"$PYTHON_BIN" -m PyInstaller --noconfirm --clean --onefile \
  --name RelayOSMCPServer \
  --distpath "$STAGE_DIR" --workpath "$STAGE_DIR/build" --specpath "$STAGE_DIR" \
  --paths src --hidden-import mcp.server --hidden-import mcp.server.auth \
  --hidden-import mcp.server.transport_security packaging/relayos_server_entry.py
cp "$STAGE_DIR/RelayOSMCPServer" "$APP_PATH/Contents/Resources/Runtime/RelayOSMCPServer"

"$PYTHON_BIN" -m PyInstaller --noconfirm --clean --onefile \
  --name RelayOSApprovals \
  --distpath "$STAGE_DIR" --workpath "$STAGE_DIR/approvals-build" --specpath "$STAGE_DIR" \
  --paths src packaging/relayos_approvals_entry.py
cp "$STAGE_DIR/RelayOSApprovals" "$APP_PATH/Contents/Resources/Runtime/RelayOSApprovals"

cp Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Assets/relayos-white.png "$APP_PATH/Contents/Resources/relayos-white.png"
cp Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Assets/relayos-black.png "$APP_PATH/Contents/Resources/relayos-black.png"

ICON_FILE="$APP_PATH/Contents/Resources/relayos.icns"
ICONSET="$STAGE_DIR/relayos.iconset"
mkdir -p "$ICONSET"
if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  for size in 16 32 128 256 512; do
    sips -s format png -z "$size" "$size" Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Assets/relayos-white.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -s format png -z "$double" "$double" Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Assets/relayos-white.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ICON_FILE" 2>/dev/null || true
fi
# Keep a PNG fallback for systems/tools that cannot create icns during a
# developer build; the runtime also assigns the native RelayOS icon.
[ -f "$ICON_FILE" ] || cp Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Assets/relayos-white.png "$APP_PATH/Contents/Resources/relayos.png"

cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDisplayName</key><string>RelayOS</string>
  <key>CFBundleName</key><string>RelayOS</string>
  <key>CFBundleExecutable</key><string>RelayOS</string>
  <key>CFBundleIdentifier</key><string>rw.shangazi.relayos</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>RelayOS uses local automation only for approved MCP actions.</string>
  <key>NSScreenCaptureUsageDescription</key><string>RelayOS captures the screen only after you approve a screen action.</string>
  <key>CFBundleIconFile</key><string>relayos.icns</string>
</dict></plist>
PLIST

if [ -n "$SIGNING_IDENTITY" ]; then
  codesign --deep --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_PATH"
else
  codesign --deep --force --sign - "$APP_PATH"
fi
codesign --verify --deep --strict "$APP_PATH"
mkdir -p "$DIST_DIR"
echo "Built $APP_PATH"
