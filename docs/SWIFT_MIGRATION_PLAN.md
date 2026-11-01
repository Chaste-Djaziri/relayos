<!-- Path: docs/SWIFT_MIGRATION_PLAN.md -->
# RelayOS: Python backend to a native Swift architecture

## Decision

Move toward a Swift-first macOS application with a separately testable Swift MCP service. Avoid an all-at-once rewrite of the authorization boundary. Current Python MCP and SQLite state remain the production reference implementation until the replacement passes the existing security and interoperability tests.

## Target layout

- `Native/LaptopBridgeApp/` — SwiftUI application, Xcode-owned signing/capabilities and previews.
- `Native/RelayOSCore/` — Swift package for configuration, SQLite state, permission and authorization policy, audit records, session/job limits, and cross-process contracts.
- `Native/RelayOSMCP/` — Swift command-line executable implementing the MCP HTTP service and OAuth endpoints, signed as a helper inside the app bundle.
- `Native/RelayOSMacServices/` — macOS-specific accessibility/screen-capture, approval UI, process supervision, and other explicit local actions.

All remote tool requests must continue to be authorized by an independently local decision. The GUI must not be the only authorization check.

## Technology choices

- **MCP:** official `modelcontextprotocol/swift-sdk` for the protocol, tool registration, and transport machinery.
- **HTTP:** an actively maintained Swift HTTP server framework (such as Hummingbird or Vapor) to bind a loopback listener and adapt the SDK's Streamable HTTP request/response transport. The SDK's transport abstraction does not alone prove parity with the current FastMCP HTTP/OAuth behavior.
- **Persistence:** SQLite (direct `SQLite3` or a maintained Swift wrapper) with migration-tested schemas and explicit transactions. Preserve the on-disk approval, OAuth, and audit data or implement an atomic, reversible migration.
- **Secrets:** Keychain Services; do not place tokens, auth codes, command argv, or approval secrets in app logs.
- **Jobs/processes:** Foundation `Process`, explicit process-group cancellation and bounded output; use actors/background work to avoid blocking SwiftUI's main actor.
- **macOS permissions:** ScreenCaptureKit/CoreGraphics, Accessibility and Apple Events with real OS consent. Do not claim Full Disk Access has a reliable universal status API.
- **Transport to internet:** keep the existing ngrok tunnel as an external dependency initially; switching app source code to Swift does not make ngrok itself a Swift implementation.

## Release phases

1. **Xcode-owned UI:** commit an Xcode app project, stable build identities, Debug/Release separation, inert UI previews and signed CI build tests. No runtime swap.
2. **Swift state and authorization core:** exact project/cwd/executable scopes; Once/Session/Always/Deny; revocation, expiration, emergency stop and persisted audit parity. Copy Python test fixture behaviors to Swift XCTest, including race/stale-token/replay cases.
3. **Swift MCP transport and tool registry:** implement the current `/mcp` contract and all existing tool schemas, response shapes, error codes and loopback control endpoints. Validate unauthenticated 401 and authenticated health 200 with an isolated port.
4. **OAuth and connection management:** preserve registered-client, PKCE, authorization and token/refresh rules; reject invalid redirects and cross-client/session tokens. Test with real supported MCP clients without altering the production endpoint.
5. **Native tools and jobs:** port filesystem access checks, process/status commands, background command jobs, limits, output pagination/cancellation, and screenshot/guidance features. Never broaden existing grants during migration.
6. **Service integration and packaging:** bundle/sign the Swift helper; remove PyInstaller from the release process only after the full Swift helper can pass the same packaged-server, crash/restart and rollback tests.
7. **Controlled handover:** back up database, config, keychain references and installed app, test a new isolated listener, verify all API/authorization cases, switch only one owned listener to production port 8765, confirm ngrok 401 and OAuth end-to-end, and keep a reversible rollback.

## Release gates

- Existing Python test suite passes, and Swift tests cover the same denial/approval/expiry/replay/emergency-stop behavior.
- A compatible database migration is validated against a copy of real data; never reset a saved approval store to avoid a migration failure.
- Signed/notarized bundle contains one native app and one Swift MCP helper, with no Python runtime included.
- Only one app owns the MCP port, and only verified/signed app-controlled processes can be recycled.
- No production deployment just to inspect UI. Use the Xcode Debug UI-only scheme and inert preview fixtures.

## Scope exclusions

Do not redesign the menu-bar/notch surfaces during the protocol migration, weaken auth to achieve parity, change the production bundle ID, or silently replace the live MCP endpoint.

## Native in-process transport implementation — 2026-11-01

The first migration slices now compile in the RelayOS app target, including a native-only isolated Debug mode. It is deliberately **experimental** and cannot replace production yet.

- `Services/NativeMCPAuthorization.swift`: fail-closed, read-only access to the existing SQLite authorization schema. Revalidates emergency-stop, SHA-256-hashed legacy OAuth access tokens, session scope and folder scope per request.
- `Services/NativeMCPProjectFiles.swift`: read-only, UTF-8 capped project listings and file reads; reject invalid sessions, traversal, symlinks escaping the project root, and oversized payloads. Permission scope is validated using current SQLite sessions rather than trusting a client-supplied root.
- `Services/NativeMCPHTTP.swift`: a native Network.framework HTTP listener bound to `127.0.0.1` on development port `18765`; MCP initialize, ping, tools/list and three read-only tools are implemented. All writes, grants, shell/process commands and unported methods are rejected.
- `Tests/LaptopBridgeAppTests/NativeMCPAuthorizationTests.swift`: authorization, expiration, emergency stop, scope, resource binding, traversal and HTTP enforcement tests.

To opt into the **in-process native experiment**, choose the existing Xcode RelayOS Debug scheme, then Edit Scheme → Run → Arguments → Environment Variables; add `RELAYOS_SWIFT_ONLY=1`. The Debug bundle identifier must be `pro.micorp.relayos.dev`. Launching it starts only a native listener on `127.0.0.1:18765`, **not** Python and not ngrok. The standard Debug run remains an inert UI preview without the experimental listener.

The current production service on `127.0.0.1:8765` and public ngrok remains Python-backed and should not be stopped until the following gates pass:
1. Replace handcrafted experimental JSON-RPC/HTTP with the official MCP Swift SDK + fully validated transport and comprehensive protocol-version/session/SSE interoperability.
2. Port **OAuth client registration, PKCE, authorization code, refresh rotation and revocation** with exact existing persistence semantics.
3. Port the **local once/session/always/deny inbox and consent** in Swift, using atomic SQLite transactions and no remotely executable approval paths.
4. Port all remaining tools with exact tool schemas, capability gating, activity audit and error behavior: write/patch, command execution, background jobs/cancellation, screenshots/guidance and support actions.
5. Eliminate all GUI calls to the Python approvals helper and packaged Python interpreter; remove helper references only after native UI equivalents are exercised.
6. Validate live protected multi-client auth flows, stable signing and recovery/rollback. Only then let the native app take port 8765 and preserve ngrok hostname and user data.

Smoke test: the native listener was started on a randomly selected loopback port and served HTTP `200` on `/health` without Python. Initial listener argument configuration was corrected after this test detected a Network.framework bind error.\n\nKnown restrictions: the development transport is JSON-only with no MCP SSE/resumability or OAuth bootstrap; the `/health` endpoint is loopback-only and intentionally reports experimental status; no external client should rely on it. Existing SQLite data is only read by the experimental code, not migrated or modified.

### Swift-only localhost checkpoint (2026-11-01)
- [x] Debug-only `RELAYOS_SWIFT_ONLY=1` starts the native MCP listener **inside** the signed/debug macOS app. No Python helper, ngrok, or production process lock is started.
- [x] Isolated developer state in `~/.relayos-swift-dev`, with owner-only test bearer token, SHA-256-digest SQLite record, and temporary NSOpenPanel-approved project sessions.
- [x] UI detects Swift-only mode and replaces unsupported Python-dependent tabs with honest disabled placeholders; Appearance remains usable.
- [x] Native `system_status`, fixed-command `list_processes`, scoped `list_project_files`, scoped `read_project_file` exposed in the local experimental MCP tool list.
- [x] OAuth token scope/resource checks and end-to-end localhost read/revoke/invalid-bearer regression tests.
- [x] Safe test build instructions in `docs/SWIFT_ONLY_LOCAL_TEST.md`; no production deployment.
- [ ] OAuth 2.1 public registration, PKCE, authorization UI, refresh/revocation and token-binding parity.
- [ ] Native Once/Session/Always approval inbox and atomic authorization for all permission-expanding commands and file writes.
- [ ] Full protocol fidelity via official MCP Swift SDK and Streamable HTTP transport; this pilot is not client-compatible for all MCP clients.
- [ ] Remaining tools, background jobs, screenshots, overlays and no-Python production packaging.
