#!/bin/sh
set -eu

./scripts/build_macos_app.sh
APP_PATH="${DIST_DIR:-dist}/Laptop Bridge.app"
DMG_PATH="${DIST_DIR:-dist}/Laptop-Bridge.dmg"
rm -f "$DMG_PATH"
hdiutil create -volname "Laptop Bridge" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH"
echo "Created $DMG_PATH"
