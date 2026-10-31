# Changelog

All notable RelayOS changes are recorded here. Entries under **Unreleased** are applied to the local development branch, not necessarily the installed app.

## Unreleased

### Changed
- Added a native `ServiceSupervisor` with bounded server/tunnel crash-retry delays, non-overlapping authenticated health probes, safe handling of stale probes during restarts, and recovery tests. The app no longer trusts an occupied MCP port without authenticating the control response, and starts the tunnel only after healthy verification.
- Added a loopback-only authenticated MCP health monitor for the native supervisor. It validates the local token file, verifies the RelayOS control-response contract and distinguishes connection failures from unauthorized or unexpected listeners. Added four Swift health-probe tests.
- The macOS command-approval dialog now explains one-time versus reusable scope, highlights **Once** by default, and labels allowlisted family permissions explicitly (for example, **Always allow git add**).
- Updated the macOS implementation roadmap with completed Phase 01 milestones, test results, and the remaining deployment/ownership acceptance checks.
- Development Python helpers are now located through validated repository discovery (or `RELAYOS_DEV_ROOT`) instead of a hardcoded home-directory path; installed builds still prefer their bundled helpers.
- Moved the observable service/approval model and local Keychain helpers out of the app entry point into `RelayOSRuntimeModel.swift`, leaving `RelayOSApp.swift` responsible for application composition only.
- Split the menu-bar panel, onboarding, desktop window, and settings SwiftUI screens into `RelayOSViews.swift`; the app entry point now focuses on state and services.

### Fixed
- Fixed the SQLite startup migration incorrectly revoking new `git add` family grants on each approval-helper process launch. Recognized scoped family grants now survive database reinitialization while legacy executable-wide permissions remain revoked; added a fresh-process regression test.
- Approval duration now follows the local person's Once/Session/Always decision, even when the MCP client requested once. Reusable `git add` grants cover varying file arguments only within the same project, working directory, and resolved Git executable; session grants expire with the originating coding session, while unrelated Git commands remain separately authorized. Added regression tests.
- Child server/ngrok exits now clear their process slot only when it still owns that specific process; restarts wait for owned subprocesses to exit, and failed launches no longer leave stale process references. Includes a regression test for delayed termination callbacks.
- macOS startup now waits for exclusive single-instance ownership before starting the MCP helper, ngrok, or approval polling. Added a native regression test for pre-lock startup.
