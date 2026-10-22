# Laptop Bridge — v0.1 cross-platform MCP agent

**Status: local prototype.** macOS and Windows, Python 3.11+. No GUI yet, no remote deployment configured, no screen control yet. Sensitive actions are gated through a local interactive approval CLI. It is not safe to expose the HTTP port publicly without a production authentication layer.

## Quick start

From project root (macOS / Windows PowerShell):

```sh
python -m venv .venv
```

macOS:
```sh
source .venv/bin/activate
python -m pip install -e '.[dev]'
laptop-bridge
```

Windows PowerShell:
```powershell
.venv\Scripts\Activate.ps1
python -m pip install -e '.[dev]'
laptop-bridge
```

The Streamable HTTP MCP endpoint is `http://127.0.0.1:8765/mcp`. Use an MCP-compatible local client for initial testing. This is NOT directly reachable by cloud ChatGPT. For ChatGPT, use an authorized Secure MCP Tunnel / remote hardened deployment subject to plan/workspace restrictions. Do not simply forward port 8765 to the internet.

## Configuration

On first launch, edit `~/.laptop-bridge/config.json` on macOS or `%USERPROFILE%\.laptop-bridge\config.json` on Windows.

Example for macOS:
```json
{
  "allowed_folders": ["/Users/YOU/Documents"],
  "allowed_apps": {"vscode": ["/usr/bin/open", "-a", "Visual Studio Code"]},
  "allowed_commands": {"git_version": ["/usr/bin/git", "--version"]},
  "max_read_bytes": 65536
}
```

Example for Windows (adjust your installed executable paths):
```json
{
  "allowed_folders": ["C:\\Users\\YOU\\Documents"],
  "allowed_apps": {"notepad": ["C:\\Windows\\System32\\notepad.exe"]},
  "allowed_commands": {"python_version": ["C:\\Python313\\python.exe", "--version"]},
  "max_read_bytes": 65536
}
```

## Approvals

Ask an MCP client to call `propose_action` with `kind="open_app"`, `target="vscode"` (when configured). On the actual laptop, run:

```sh
laptop-bridge-approvals list
laptop-bridge-approvals approve REQUEST_ID
```

Type `APPROVE` after reviewing the exact argv. Then have your MCP client call `execute_approved_action` with the request ID within five minutes. Each approved request is used once.

## Security boundaries (v0.1)

- Default interface binds to loopback only; **never expose it directly**.
- Read-only file operations restricted to configured folders, resolving symlinks.
- Commands and applications must be explicitly allowlisted as argument arrays, never shell strings.
- Sensitive actions use local interactive confirmation and single-use approval IDs.
- Do not allow untrusted users or processes to modify the local state/configuration directory.
- Treat text returned from files/commands as potentially hostile prompt injection.
- The JSON approval store is a single-user prototype; concurrent requests, multiple processes, and privileged/hostile local users require a transaction-safe datastore and OS-protected authorization.
- Commands themselves can mutate files or access the network: allowlist only audited, narrowly scoped commands.
- Local MCP connections have no application-level authentication in v0.1. A hardened authenticated gateway, TLS/tunnel, audit log, device pairing, per-tool policy, stronger approval UX, and a separate low-privilege agent are prerequisites for remote control.

## Run checks

```sh
python -m compileall -q src
pytest -q
```

## Next milestones

1. Native menubar/tray approval app with signed action summaries and device keychain credential storage.
2. Hardened private transport, identity and authorization, replay prevention, concurrent request safety, structured audit events.
3. Safe write/move operations with path-limited capabilities, backups and previews.
4. Screenshot tool with visible consent; GUI control via macOS Accessibility / Windows UI Automation, per-session scoped approvals and emergency stop.
5. Packaged installers and signed updates for both operating systems.

Docs: https://developers.openai.com/api/docs/guides/secure-mcp-tunnels and https://help.openai.com/en/articles/12584461-connecting-custom-mcp-servers-in-chatgpt
