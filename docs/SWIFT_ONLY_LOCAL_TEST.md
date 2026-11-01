<!-- Path: docs/SWIFT_ONLY_LOCAL_TEST.md -->
# RelayOS Swift-only development mode

## Safety boundary

The installed production application remains at `/Applications/RelayOS.app` and continues to use its existing Python-backed MCP service on port `8765`. The Xcode Debug app (`pro.micorp.relayos.dev`) is a **separate identity** and may run **Swift-only** on loopback port `18765`. It never installs over, restarts or claims the installed agent's process lock. The native development store is `~/.relayos-swift-dev`, not `~/.laptop-bridge`.

Only read-only native MCP tools are presently supported: `system_status`, `list_processes`, `list_project_files`, `read_project_file`. OAuth onboarding, pending command decisions, write/patch, commands, jobs, screenshot/guidance, desktop actions and other features are **not yet implemented in Swift**. They are disabled in this run mode; they must not silently fall back to Python.

## Test without launching or installing anything

Run from the repository root after approval:

```bash
sh scripts/test_swift_only.sh
```

This runs native tests, including real loopback HTTP and local authorization, followed by an Xcode Debug build with signing disabled. It does not install, replace, launch or terminate `/Applications/RelayOS.app`.

## Launch only the native Swift development app

In Xcode select the standard `RelayOS` scheme → **Edit Scheme → Run → Arguments → Environment Variables**:

- `RELAYOS_SWIFT_ONLY` = `1` (checked).
- Remove or uncheck the deprecated `RELAYOS_NATIVE_MCP_EXPERIMENT`; it is ignored by the new launcher.
- Leave `RELAYOS_XCODE_UI_PREVIEW` absent so Run opens the real Settings window; Canvas continues to use sample-only `#Preview` data.

Press **Command+R**. The Debug app creates `~/.relayos-swift-dev` with restricted filesystem permissions, starts its native in-process listener on `127.0.0.1:18765`, and shows a Swift-only settings section. It does not start a Python helper or ngrok.

## Verify its local endpoints

```bash
# Unauthenticated GET /health should return 200 with native-experimental.
curl -i http://127.0.0.1:18765/health

# Unauthenticated MCP must return 401.
curl -i -X POST http://127.0.0.1:18765/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

Use the native app's **Copy test token** button only for local testing. The token is stored in a user-only file, expires on a 24-hour rolling window when Debug starts, and should never be committed or used on a public tunnel. The **Choose folder** button opens a real `NSOpenPanel`; approving it creates a scoped one-hour project session. Copy the session ID to test `list_project_files` and `read_project_file`.

No public forwarding, OAuth connection migration, signing change or production port handover is authorized by this development test.

## Remaining production parity gates

The current Swift HTTP listener is an experimental JSON-only implementation, not a replacement for the official MCP Swift SDK's Streamable HTTP/SSE transport. Before a full switchover, port OAuth 2.1/PKCE and local grant decisions, full MCP tool contracts, command jobs, native desktop/screen guidance, safe token storage and revocation, and production service supervision. Validate all parity tests, signed application identity and TCC permissions against a backup before moving the native listener to `8765`.
