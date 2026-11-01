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
