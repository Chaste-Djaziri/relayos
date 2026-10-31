# Changelog

All notable RelayOS changes are recorded here. Entries under **Unreleased** are applied to the local development branch, not necessarily the installed app.

## Unreleased

### Changed
- Added client-proposed, locally approved literal `scope_prefix` for repeatable project commands (for example `git commit`, `npm install`, or `npm run build`). Reusable prefixes are constrained to the resolved executable, authorized project, working directory, local duration and immutable leading argv tokens. Once remains exact; arbitrary shells/interpreters do not support reusable prefixes. Added approval-tampering, session, revocation and database-reopen regression tests (96 Python tests passing).
- Added `scripts/smoke_packaged_mcp.py` to start the signed bundle's MCP helper with isolated temporary state and an ephemeral loopback port, verify anonymous rejection and authenticated status, and safely terminate only the test subprocess.
- Added an opt-in native integration test (`RELAYOS_TEST_LIVE_MCP=1`) that checks the authenticated loopback health endpoint without modifying or restarting the live MCP service.
- Added a native `ServiceSupervisor` with bounded server/tunnel crash-retry delays, non-overlapping authenticated health probes, safe handling of stale probes during restarts, and recovery tests. The app no longer trusts an occupied MCP port without authenticating the control response, and starts the tunnel only after healthy verification.
- Added a loopback-only authenticated MCP health monitor for the native supervisor. It validates the local token file, verifies the RelayOS control-response contract and distinguishes connection failures from unauthorized or unexpected listeners. Added four Swift health-probe tests.
- The macOS command-approval dialog now explains one-time versus reusable scope, highlights **Once** by default, and labels allowlisted family permissions explicitly (for example, **Always allow git add**).
- Updated the macOS implementation roadmap with completed Phase 01 milestones, test results, and the remaining deployment/ownership acceptance checks.
- Development Python helpers are now located through validated repository discovery (or `RELAYOS_DEV_ROOT`) instead of a hardcoded home-directory path; installed builds still prefer their bundled helpers.
- Moved the observable service/approval model and local Keychain helpers out of the app entry point into `RelayOSRuntimeModel.swift`, leaving `RelayOSApp.swift` responsible for application composition only.
- Split the menu-bar panel, onboarding, desktop window, and settings SwiftUI screens into `RelayOSViews.swift`; the app entry point now focuses on state and services.

### Fixed
- Ignore stale MCP health responses after a managed server crash, preventing a response from the dead process from resetting restart cooldown or marking the new server healthy. Added a crash-generation regression test.
- Pre-create the authenticated loopback control token before binding the Python MCP listener so fresh native installations can verify the server without an unauthenticated bootstrap request. Added a startup-order regression test.
- Fixed the SQLite startup migration incorrectly revoking new `git add` family grants on each approval-helper process launch. Recognized scoped family grants now survive database reinitialization while legacy executable-wide permissions remain revoked; added a fresh-process regression test.
- Approval duration now follows the local person's Once/Session/Always decision, even when the MCP client requested once. Reusable `git add` grants cover varying file arguments only within the same project, working directory, and resolved Git executable; session grants expire with the originating coding session, while unrelated Git commands remain separately authorized. Added regression tests.
- Child server/ngrok exits now clear their process slot only when it still owns that specific process; restarts wait for owned subprocesses to exit, and failed launches no longer leave stale process references. Includes a regression test for delayed termination callbacks.
- macOS startup now waits for exclusive single-instance ownership before starting the MCP helper, ngrok, or approval polling. Added a native regression test for pre-lock startup.
