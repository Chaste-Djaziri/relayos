#!/bin/sh
set -eu

APP_NAME="Laptop Bridge"
DIST_DIR="${DIST_DIR:-dist}"
SIGNING_IDENTITY="${LAPTOP_BRIDGE_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${LAPTOP_BRIDGE_NOTARY_PROFILE:-}"
if [ -z "${PYTHON_BIN:-}" ] && [ -x ".venv/bin/python" ]; then
  PYTHON_BIN=".venv/bin/python"
else
  PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || command -v python)}"
fi

if [ -z "${PYTHON_BIN}" ]; then
  echo "Python 3.11+ is required; set PYTHON_BIN to the active interpreter." >&2
  exit 1
fi

"${PYTHON_BIN}" -m pip install -e '.[dev]'
rm -rf "build/${APP_NAME}" "${DIST_DIR}/${APP_NAME}.app"
"${PYTHON_BIN}" -m PyInstaller --noconfirm --clean --windowed \
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
