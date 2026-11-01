# Path: scripts/test_swift_only.sh
# Safe native-only test build. Never launches or replaces /Applications/RelayOS.app.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

printf '%s\n' '== Swift-only native tests =='
swift test --package-path Native/LaptopBridgeApp

printf '%s\n' '== Xcode Debug compilation (no signing, no installation) =='
xcodebuild \
  -project Native/LaptopBridgeApp/RelayOS.xcodeproj \
  -scheme RelayOS \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build

printf '%s\n' 'Swift-only tests and Xcode compilation passed. Live app untouched.'
