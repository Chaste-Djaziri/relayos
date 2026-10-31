# Changelog

All notable RelayOS changes are recorded here. Entries under **Unreleased** are applied to the local development branch, not necessarily the installed app.

## Unreleased

### Changed
- Development Python helpers are now located through validated repository discovery (or `RELAYOS_DEV_ROOT`) instead of a hardcoded home-directory path; installed builds still prefer their bundled helpers.
- Moved the observable service/approval model and local Keychain helpers out of the app entry point into `RelayOSRuntimeModel.swift`, leaving `RelayOSApp.swift` responsible for application composition only.
- Split the menu-bar panel, onboarding, desktop window, and settings SwiftUI screens into `RelayOSViews.swift`; the app entry point now focuses on state and services.

### Fixed
- Child server/ngrok exits now clear their process slot only when it still owns that specific process; restarts wait for owned subprocesses to exit, and failed launches no longer leave stale process references. Includes a regression test for delayed termination callbacks.
- macOS startup now waits for exclusive single-instance ownership before starting the MCP helper, ngrok, or approval polling. Added a native regression test for pre-lock startup.
