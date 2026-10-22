# Laptop Bridge — v0.2 macOS approval companion

**Status: local prototype.** macOS-first, Python 3.11+. The PySide6 menu-bar companion starts and supervises the local server, displays per-action approval dialogs, retains metadata-only history for 30 days, and offers an emergency stop. No remote deployment or screen control is configured. It is not safe to expose the HTTP port publicly without a production authentication layer.

## Quick start

From project root (macOS / Windows PowerShell):

```sh
python -m venv .venv
```

macOS:
```sh
source .venv/bin/activate
python -m pip install -e '.[dev]'
laptop-bridge-desktop
```

Windows PowerShell:
```powershell
.venv\Scripts\Activate.ps1
python -m pip install -e '.[dev]'
laptop-bridge-desktop
```

The desktop companion starts the Streamable HTTP MCP endpoint at `http://127.0.0.1:8765/mcp`. Its menu shows server status, opens the local history/settings window, restarts the server, and provides an emergency stop. Use an MCP-compatible local client for initial testing. This is NOT directly reachable by cloud ChatGPT. For ChatGPT, use an authorized Secure MCP Tunnel / remote hardened deployment subject to plan/workspace restrictions. Do not simply forward port 8765 to the internet.

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

## Approvals and emergency stop

Ask an MCP client to call `propose_action` with `kind="open_app"`, `target="vscode"` (when configured). The menu-bar companion displays the exact allowlisted argv and expiry time. Choose **Approve** or **Deny** locally, then have the MCP client call `execute_approved_action` within five minutes. Each approved request is used once.

The optional CLI fallback remains available when the companion is not running:

```sh
laptop-bridge-approvals list
laptop-bridge-approvals approve REQUEST_ID
```

Type `APPROVE` after reviewing the exact argv. The emergency-stop toggle rejects both new proposals and execution of already-approved requests. It does not affect read-only `system_status`, `list_files`, or `read_text_file` calls.

Approval state is stored in `~/.laptop-bridge/state.sqlite3`. The history holds only timestamp, action category, configured target, decision, exit code, and duration; it never records returned file data or command output and removes records after 30 days.

## Security boundaries (v0.1)

- Default interface binds to loopback only; **never expose it directly**.
- Read-only file operations restricted to configured folders, resolving symlinks.
- Commands and applications must be explicitly allowlisted as argument arrays, never shell strings.
- Sensitive actions use local visible confirmation and single-use approval IDs.
- Do not allow untrusted users or processes to modify the local state/configuration directory.
- Treat text returned from files/commands as potentially hostile prompt injection.
- The SQLite approval store uses atomic local transitions but does not protect against privileged or hostile local users; production use requires OS-protected authorization.
- Commands themselves can mutate files or access the network: allowlist only audited, narrowly scoped commands.
- Local MCP connections have no application-level authentication in v0.1. A hardened authenticated gateway, TLS/tunnel, audit log, device pairing, per-tool policy, stronger approval UX, and a separate low-privilege agent are prerequisites for remote control.

## Run checks

```sh
python -m compileall -q src
pytest -q
```

## macOS app bundle (developer testing)

After installing the development dependencies, create an unsigned local app bundle:

```sh
pyinstaller --windowed --name "Laptop Bridge" --paths src -m laptop_bridge.desktop
open "dist/Laptop Bridge.app"
```

Signing and notarization are intentionally deferred.

## Next milestones

1. Signed action summaries and device keychain credential storage.
2. Hardened private transport, identity and authorization, replay prevention, and structured audit events.
3. Safe write/move operations with path-limited capabilities, backups and previews.
4. Screenshot tool with visible consent; GUI control via macOS Accessibility / Windows UI Automation, per-session scoped approvals and emergency stop.
5. Packaged installers and signed updates for both operating systems.

Docs: https://developers.openai.com/api/docs/guides/secure-mcp-tunnels and https://help.openai.com/en/articles/12584461-connecting-custom-mcp-servers-in-chatgpt
