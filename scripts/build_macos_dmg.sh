#!/bin/sh
set -eu

./scripts/build_relayos_app.sh
APP_PATH="${DIST_DIR:-dist}/RelayOS.app"
DMG_PATH="${DIST_DIR:-dist}/RelayOS.dmg"
rm -f "$DMG_PATH"
hdiutil create -volname "RelayOS" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH"
echo "Created $DMG_PATH"
