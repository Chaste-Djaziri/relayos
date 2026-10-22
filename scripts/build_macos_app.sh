#!/bin/sh
set -eu

APP_NAME="Laptop Bridge"
DIST_DIR="${DIST_DIR:-dist}"
SIGNING_IDENTITY="${LAPTOP_BRIDGE_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${LAPTOP_BRIDGE_NOTARY_PROFILE:-}"

python -m pip install -e '.[dev]'
rm -rf "build/${APP_NAME}" "${DIST_DIR}/${APP_NAME}.app"
pyinstaller --noconfirm --clean --windowed \
  --name "${APP_NAME}" \
  --paths src \
  --osx-bundle-identifier "rw.shangazi.laptop-bridge" \
  --osx-entitlements-file packaging/macos.entitlements \
  -m laptop_bridge.desktop

APP_PATH="${DIST_DIR}/${APP_NAME}.app"
if [ -n "${SIGNING_IDENTITY}" ]; then
  codesign --deep --force --options runtime --timestamp \
    --entitlements packaging/macos.entitlements \
    --sign "${SIGNING_IDENTITY}" "${APP_PATH}"
  codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
  if [ -n "${NOTARY_PROFILE}" ]; then
    xcrun notarytool submit "${APP_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
    xcrun stapler staple "${APP_PATH}"
  else
    echo "Signed app created. Set LAPTOP_BRIDGE_NOTARY_PROFILE to notarize it."
  fi
else
  echo "Unsigned developer app created at ${APP_PATH}."
  echo "Set LAPTOP_BRIDGE_SIGNING_IDENTITY for a Developer ID build."
fi
