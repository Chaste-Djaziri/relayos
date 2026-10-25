# Laptop Bridge — Desktop Companion

**Status: macOS and Windows 10/11 companion.** Python 3.11+. On first launch, the companion walks you through ngrok setup, capability choices, and client connections. Each installation gets its own HTTPS endpoint and secrets stay in the platform credential store; no project credentials are shipped.

No mouse/keyboard injection or unrestricted computer control is configured or permitted. It is not safe to expose the HTTP port publicly without a production authentication layer.

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

The desktop companion starts the Streamable HTTP MCP endpoint at `http://127.0.0.1:8765/mcp`. Its menu shows server status, overlay status, active coding sessions, folder picker for sessions, guidance controls, local history/settings window, server restart, and an emergency stop.

## Windows 10/11

The Windows companion is a standard main-window application: every control lives in its dashboard and closing the window stops the local MCP server and ngrok tunnel. It does not run hidden in the notification area.

- The ngrok authtoken is stored only in the current user's Windows Credential Manager entry; it is never written to `config.json` or passed as a command-line argument.
- Screen snapshots use the active desktop display; guidance uses a click-through, always-on-top overlay. Passive click metadata is collected only during an explicit active guidance session—no keyboard data, clicks, or commands are injected or replayed.
- The setup wizard can invoke `winget install ngrok.ngrok`; if winget is unavailable, it opens the official ngrok download page. Install Git for Windows separately to use `apply_project_patch`.
- Windows Privacy settings or endpoint-protection software can restrict capture or global hooks. The dashboard reports capture and passive-observation availability.

### Build and install on Windows

Install Python 3.11+ and [Inno Setup 6](https://jrsoftware.org/isinfo.php). From PowerShell in the project root:

```powershell
.venv\Scripts\Activate.ps1
./scripts/build_windows.ps1 -Python .venv\Scripts\python.exe -Version 0.1.0
```

The installer is written to `dist\installer\LaptopBridge-Setup-<version>.exe`. It installs per user under `%LOCALAPPDATA%`, creates a Start Menu shortcut, and can optionally create a desktop shortcut. To Authenticode-sign the application executable, set `LAPTOP_BRIDGE_SIGNING_CERTIFICATE` (and, when applicable, `LAPTOP_BRIDGE_SIGNING_PASSWORD`) before building. Unsigned developer builds can trigger Microsoft Defender SmartScreen; install only builds you trust.

## First-run setup and client connections

Open **Set up or reconfigure…** from the menu-bar companion. Enter an ngrok authtoken and a reserved ngrok domain such as `bridge.ngrok.app`. Laptop Bridge starts the ngrok agent and forwards the stable HTTPS endpoint to the loopback MCP server. The authtoken is stored only in macOS Keychain; non-secret configuration is kept in `~/.laptop-bridge/config.json`.

The wizard starts with system status only. Screen guidance and project tools are opt-in because they require additional macOS permissions and explicit approval.

ChatGPT, Gemini, and other MCP clients use the public OAuth endpoint shown in the dashboard. Paste the endpoint ending in `/mcp` into the client's custom MCP connection dialog; the first connection opens a local approval dialog. No client ID or secret is normally required.

### MCP client connection

MCP clients require a public HTTPS Streamable HTTP endpoint. Laptop Bridge keeps its server loopback-only and uses an ngrok agent to expose it through a reserved domain.

1. Reserve a stable domain in the ngrok dashboard and create an authtoken.
2. Enter both values in the Laptop Bridge setup wizard. The companion starts ngrok with the token supplied through the process environment.
3. In the MCP client, enter `https://<your-domain>/mcp`. Dynamic Client Registration supplies the credentials automatically. Approve the connection in the visible Laptop Bridge companion dialog.

The public endpoint accepts only bearer tokens issued after local approval. Authorization requests require an HTTPS callback, enforce PKCE and the single `mcp` scope, issue one-hour access tokens, rotate refresh tokens, and expire the connection after 30 days. Use **Disconnect** in the companion's Connected MCP Clients section, or Emergency Stop, to revoke it immediately.

To create a Finder-launchable app, run `./scripts/build_macos_app.sh` and open `dist/Laptop Bridge.app`.

## Native macOS companion (preview)

The native Swift companion targets macOS 14 Sonoma and uses a SwiftUI/AppKit menu-bar surface. It keeps the Python MCP server as the tool runtime while moving the interactive shell and process supervision into a responsive native app.

Build the native package locally with:

```sh
swift build --package-path Native/LaptopBridgeApp
```

The native target currently supervises the existing Python MCP/OAuth listener on `127.0.0.1:8765` and the configured ngrok agent while the Swift edge proxy and OAuth service are migrated.

## macOS Screen Recording Permissions

Screen capture requires the user to grant macOS Screen Recording permission to Laptop Bridge (or your terminal / Python environment during development):

1. On first `screen_snapshot` request, macOS may display a permission prompt.
2. If needed, grant permission in **System Settings > Privacy & Security > Screen Recording** and ensure Laptop Bridge is toggled on.
3. Grant **System Settings > Privacy & Security > Accessibility** access to Laptop Bridge for cross-app overlay behavior and pointer observation. No clicks or keystrokes are injected.
4. `screen_snapshot` captures only the display containing the focused app (falling back to the display containing the pointer).
5. Captures occur **only after an explicit MCP tool invocation**; there is no background, continuous, or unprompted recording.
6. Screenshot image bytes are transient, returned directly to the MCP caller, immediately deleted from local state, and never saved in SQLite history.

## Continuous Guidance Sessions

For a multi-step walkthrough, ChatGPT must first call `start_guidance_session` (default maximum: 15 minutes). The companion shows a persistent “Screen sharing active” tray indicator. Frames are still captured only when ChatGPT calls `refresh_guidance_screen`; there is no background video stream. Call `stop_guidance_session` when finished, or the session expires automatically.

During an active session, `show_guidance` can place the click-through triangle and optional bubble for each step. `get_guidance_events` returns passive click metadata (display, coordinates, button, modifiers, and timestamp) so ChatGPT can confirm that the user acted. No keyboard contents, typed text, clipboard data, clicks, or commands are injected or replayed. Screen images and click events are transient session data and are not retained in history.

## Visual Guidance Overlay

Laptop Bridge provides an always-on-top, click-through PySide6 instructional overlay:

- **Agent Guide Cursor**: A distinct electric cyan and slate pointer labeled "Laptop Bridge" moves smoothly from the user's current cursor position to an agent-selected target location.
- **Pulsing Target Ring**: An animated concentric target ring with crosshair ticks marks the exact element or coordinate of interest.
- **Instructional Bubble**: An optional dark glassmorphism card displays the action title and explanation.
- **Trailing Mode**: After arriving at the target and pausing, the guide cursor automatically enters trailing mode, following behind the user's real mouse cursor to assist without controlling or blocking input.
- **Click-Through**: Uses `Qt.WindowType.WindowTransparentForInput` and `WA_TransparentForMouseEvents` so the user can interact freely with apps beneath the overlay.
- **Timeout and Clear**: Guidance can specify a timeout in seconds or remain visible until explicitly cleared via `clear_guidance` or the companion tray menu.
- **Emergency Stop**: Immediately clears all visible guidance overlays across all displays.

Permission-expanding tools are marked as write/destructive MCP actions so ChatGPT can apply its native confirmation flow when the connected app's action controls require it. MCP annotations are hints, not a server-verifiable record of a confirmation click; configure ChatGPT to require confirmation for these actions. Clients without an in-chat confirmation flow can use the companion approval fallback. macOS Screen Recording, Accessibility, and Files & Folders / Full Disk Access permissions must still be granted in macOS Settings.

## Follow-ups and reminders

`record_follow_up_request`, `list_pending_follow_ups`, and `complete_follow_up` retain only a title, schedule, expiration, project-session reference, and metadata. After recording one, ask ChatGPT to schedule a reminder or recurring task using the returned ID. The MCP server cannot create a ChatGPT heartbeat autonomously for every account; scheduling remains a ChatGPT/workspace feature.

## 60-Minute Project Coding Sessions and Command Grants

For coding tasks, users can grant scoped, time-limited access to specific project directories:

- **Folder Request & Approval**: `propose_project_session(project_path)` requests access to one exact folder for 60 minutes. ChatGPT should confirm the permission-expanding request in chat; use the companion's folder picker/dialog as a fallback. Call `approve_project_session(request_id)` in ChatGPT to approve and activate, or `project_session_status(request_id)` after approving through the companion. A separate folder session is required for another directory.
- **MCP Coding Tools**:
  - `propose_project_session(project_path)`: Request approval for an existing project folder.
  - `project_session_status(request_id)`: Activate an approved project session and obtain its session ID.
  - `list_project_files(session_id, folder)`: List direct children inside the approved project.
  - `read_project_file(session_id, path)`: Read UTF-8 text file up to 1 MiB.
  - `write_project_file(session_id, path, content)`: Create or update UTF-8 file up to 1 MiB.
  - `apply_project_patch(session_id, patch)`: Apply unified diffs via `/usr/bin/git apply` without shell interpolation.
  - `authorize_project_command(session_id, argv, cwd, grant)`: Confirm exact argv once (`grant="once"`) or save an executable grant for this project (`grant="always"`).
  - `run_project_command(session_id, argv, cwd, authorization_token)`: Run an approved non-interactive command with `shell=False`, 120s timeout, DEVNULL stdin, and 8192-byte output cap.
  - `list_saved_command_grants()` / `revoke_saved_command_grant(grant_id)`: Review and revoke persistent command grants in ChatGPT; they are also listed in companion settings.
- **Security Boundaries**:
  - All paths and working directories are validated against the resolved project root. Path traversal (`..`) and symlink escapes pointing outside the root are strictly rejected with `PermissionError`.
  - Privilege escalation (`sudo`, `su`, `doas`) is blocked.
  - A one-use command grant matches the resolved executable, exact argv, and exact working directory. An "always" grant matches a resolved executable within one project, with any arguments, until revoked (for example, it permits `npm run build` and other npm arguments).
  - Commands run as the logged-in macOS user and are not OS-sandboxed. Even with a project-scoped grant, an executable or npm script may access any files/macOS resources available to Laptop Bridge; inspect the executable and project before choosing "always".
  - Activating Emergency Stop immediately terminates active project sessions and cancels all pending/running operations.

## MCP Tools Reference

| Tool | Description |
| --- | --- |
| `system_status` | Read OS, hostname, processor utilization, memory, and battery. |
| `list_files` | List direct children of a configured allowed folder. |
| `read_text_file` | Read an approved small UTF-8 text file. |
| `propose_action` | Request human approval for allowlisted app or command. |
| `execute_approved_action` | Run a single-use approved action within 5 minutes. |
| `screen_snapshot` | On-demand capture of the active display with metadata and image content. |
| `start_guidance_session` | Start an explicit, bounded visual guidance session. |
| `guidance_session_status` | Read the active guidance session and expiry. |
| `refresh_guidance_screen` | Capture one current display frame for an active session. |
| `get_guidance_events` | Poll passive click metadata from an active session. |
| `stop_guidance_session` | Stop sharing and clear the guidance session. |
| `show_guidance` | Render click-through visual overlay and guide cursor on target display. |
| `clear_guidance` | Remove visible guidance overlays immediately. |
| `propose_project_session` | Request human approval for a 60-minute project coding session. |
| `approve_project_session` | Approve and activate a pending folder session from ChatGPT. |
| `project_session_status` | Activate approved coding session and return session token. |
| `list_project_files` | List files within the active project session root. |
| `read_project_file` | Read a file within the active project session root. |
| `write_project_file` | Write a file within the active project session root. |
| `apply_project_patch` | Apply unified diff patch inside project session with `git apply`. |
| `authorize_project_command` | Approve an exact command once or save an executable grant for the project. |
| `run_project_command` | Execute argv only with a valid one-use or persistent command grant. |
| `list_saved_command_grants` | List persistent project-scoped executable grants. |
| `revoke_saved_command_grant` | Revoke a persistent executable grant. |
| `record_follow_up_request` | Record an unfinished-task reminder for ChatGPT to schedule or revisit. |
| `list_pending_follow_ups` | List pending unfinished-task reminders. |
| `complete_follow_up` | Mark an unfinished-task reminder complete. |

## Run checks and tests

```sh
python -m compileall -q src
pytest -v
```

## macOS app bundle (developer testing)

Build and test an unsigned local macOS app bundle:

```sh
./scripts/build_macos_app.sh
open "dist/Laptop Bridge.app"
```

For a Developer ID build, set `LAPTOP_BRIDGE_SIGNING_IDENTITY`. To notarize, also set `LAPTOP_BRIDGE_NOTARY_PROFILE` to an `xcrun notarytool` keychain profile. The script verifies signed bundles and staples notarization when configured.
