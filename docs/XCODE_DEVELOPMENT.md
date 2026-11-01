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

- The Xcode Debug bundle uses `pro.micorp.relayos.dev` and shows an **inert demo window**. It neither takes the production instance lock nor starts the MCP server or ngrok.
- The Release bundle identifier is `pro.micorp.relayos`. The currently installed legacy app may still use `rw.shangazi.relayos`; these are different macOS privacy identities. **Do not install an Xcode Release build over the live app**: it does not include the Python runtime helpers.
- Keep a consistent signing team and certificate on successive builds. Ad-hoc signing may cause macOS screen-recording and accessibility permissions to be reported as missing after replacement.
- **Do not grant Full Disk Access to the Debug UI preview** just to experiment with appearance settings.
- The Xcode project has user-adjusted app-icon and scheme settings. They have been preserved. **Do not re-run XcodeGen until any other manually edited project/scheme settings are mirrored in `project.yml`**; project generation can overwrite them. The app identity, category, version and app-icon build setting are mirrored. Do not commit personal signing credentials or private keys.
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
