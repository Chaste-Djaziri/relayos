#!/bin/sh
# Path: scripts/build_macos_dmg.sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

./scripts/build_relayos_app.sh

DIST_DIR=${DIST_DIR:-"$ROOT_DIR/dist"}
APP_PATH="$DIST_DIR/RelayOS.app"
DMG_PATH="$DIST_DIR/RelayOS.dmg"
STAGE_PATH="$DIST_DIR/.dmg-layout"

test -d "$APP_PATH" || { echo "Missing RelayOS.app" >&2; exit 1; }
codesign --verify --deep --strict "$APP_PATH"
test -x "$APP_PATH/Contents/MacOS/RelayOS"
test -x "$APP_PATH/Contents/Resources/Runtime/RelayOSMCPServer"
test -x "$APP_PATH/Contents/Resources/Runtime/RelayOSApprovals"
test -x "$APP_PATH/Contents/Resources/Runtime/RelayOSScreenCapture"

rm -rf "$STAGE_PATH"
mkdir -p "$STAGE_PATH"
cp -R "$APP_PATH" "$STAGE_PATH/RelayOS.app"
ln -s /Applications "$STAGE_PATH/Applications"

rm -f "$DMG_PATH"
hdiutil create -volname "RelayOS" -srcfolder "$STAGE_PATH" -ov -format UDZO "$DMG_PATH"
test -s "$DMG_PATH"
hdiutil verify "$DMG_PATH"

# The disk image is distributable even without notarization, but macOS
# Gatekeeper may require explicit user confirmation for ad-hoc signatures.
# Do not imply notarization when a Developer ID signing identity is absent.
if [ -n "${RELAYOS_NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$RELAYOS_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

echo "Created $DMG_PATH"
