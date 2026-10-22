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
  --hidden-import AppKit \
  --hidden-import Foundation \
  --osx-entitlements-file packaging/macos.entitlements \
  packaging/desktop_entry.py

APP_PATH="${DIST_DIR}/${APP_NAME}.app"
/usr/libexec/PlistBuddy -c "Add :NSScreenCaptureUsageDescription string Laptop Bridge captures the active display only when you explicitly request screen guidance." "${APP_PATH}/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NSAccessibilityUsageDescription string Laptop Bridge uses Accessibility only for its click-through overlay and pointer observation; it never injects input." "${APP_PATH}/Contents/Info.plist" 2>/dev/null || true
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
  # PyInstaller ad-hoc signs the bundle before we add privacy usage strings.
  # Re-sign after the plist edits so macOS TCC can validate the app identity
  # and honor the user's Files & Folders / Full Disk Access grants.
  codesign --deep --force --sign - \
    --entitlements packaging/macos.entitlements \
    "${APP_PATH}"
  codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
  echo "Ad-hoc signed developer app created at ${APP_PATH}."
  echo "Set LAPTOP_BRIDGE_SIGNING_IDENTITY for a Developer ID build."
fi
