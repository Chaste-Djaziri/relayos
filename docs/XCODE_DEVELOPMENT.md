<!-- Path: docs/XCODE_DEVELOPMENT.md -->
# RelayOS native development in Xcode

The existing SwiftUI sources remain under `Native/LaptopBridgeApp/Sources/LaptopBridgeApp`. The reproducible macOS Xcode app target is generated from `Native/LaptopBridgeApp/project.yml`.

## Initial setup

1. Install Xcode from Apple and sign in under **Xcode → Settings → Accounts**.
2. Run `cd ~/Documents/GitHub/laptop-bridge/Native/LaptopBridgeApp && xcodegen generate`.
3. Open `Native/LaptopBridgeApp/RelayOS.xcodeproj` rather than only `Package.swift`.
4. In the project navigator, select the blue **RelayOS** project, then the **RelayOS** app target.
5. Open **Signing & Capabilities**. Enable **Automatically manage signing** and choose your Apple Developer **Team**.
6. Use **General → Identity** to manage version/build numbers, app identity, and supported macOS deployment version.
7. Choose **RelayOS UI Preview** and **My Mac** in the scheme selector.

The project uses the existing app implementation, not a copied set of files. Do not create a second `@main` app entry point.

## Signing and system permissions

- The Xcode Debug bundle uses `rw.shangazi.relayos.dev` and shows an **inert demo window**. It neither takes the production instance lock nor starts the MCP server or ngrok.
- The Release bundle identifier matches the existing installed production app: `rw.shangazi.relayos`. **Do not run or install an Xcode Release build over the real app yet**: it does not bundle the Python runtime helpers.
- Keep a consistent signing team and certificate on successive builds. Ad-hoc signing may cause macOS screen-recording and accessibility permissions to be reported as missing after replacement.
- **Do not grant Full Disk Access to the Debug UI preview** just to experiment with appearance settings.
- The generated Xcode project is reproducible. Edits made exclusively in generated project settings may be overwritten by running XcodeGen again. Keep any permanent non-secret build-setting changes in `project.yml`; do not commit personal signing credentials or private keys.
- Xcode's Debug build is for UI iteration, not production distribution. The currently working production packager is `scripts/build_relayos_app.sh`, run from the repository root after explicit local approval and with an isolated `DIST_DIR`.

## Build, preview, test

- **Command+B** builds the selected Xcode app target.
- **Command+R** runs the safe Debug UI showcase. It does not affect the active RelayOS connector.
- **Editor → Canvas** renders `Views/WindowPreviewFixtures.swift`, `Views/XcodePreviewShowcaseView.swift`, and component `#Preview` declarations. Open one of those files, then resume the canvas.
- **Command+U** runs the Xcode test target; the separate package regression suite remains `swift test --package-path Native/LaptopBridgeApp`.
- Use **Product → Archive** only after the production app build target and helper packaging are integrated into Xcode. Today the Release Xcode archive is **not a supported final distribution artifact**.

## Distribution later

To distribute directly outside the Mac App Store, obtain a **Developer ID Application** identity, use Hardened Runtime and appropriate entitlements, archive, and notarize via **Xcode → Window → Organizer → Distribute App**. Debug Apple Development signing and Developer ID distribution signing are different. A paid Apple Developer Program membership is required for Developer ID distribution.

## Architecture boundary

The UI is SwiftUI today; `src/laptop_bridge` still owns the production MCP/OAuth/authz implementation. See `docs/SWIFT_MIGRATION_PLAN.md`. Do not start both Python and Swift MCP servers on port 8765 simultaneously; preserve the live endpoint and saved SQLite authorization records throughout migration.
