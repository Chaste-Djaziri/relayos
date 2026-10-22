# Laptop Bridge — v0.3 macOS Visual Guidance & Project Coding Sessions

**Status: local prototype.** macOS-first, Python 3.11+. The PySide6 menu-bar companion starts and supervises the local MCP server, displays per-action and project-session approval dialogs, renders a transparent click-through instructional overlay with a trailing guide cursor, manages ScreenCaptureKit display capture on explicit request, retains metadata-only history for 30 days, and offers an emergency stop.

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

## macOS Screen Recording Permissions

Screen capture requires the user to grant macOS Screen Recording permission to Laptop Bridge (or your terminal / Python environment during development):

1. On first `screen_snapshot` request or via the companion status window **Request Permission** button, macOS displays a permission prompt.
2. If needed, grant permission in **System Settings > Privacy & Security > Screen Recording** and ensure Laptop Bridge is toggled on.
3. `screen_snapshot` captures only the display containing the focused app (falling back to the display containing the pointer).
4. Captures occur **only after an explicit MCP tool invocation**; there is no background, continuous, or unprompted recording.
5. Screenshot image bytes are transient, returned directly to the MCP caller, immediately deleted from local state, and never saved in SQLite history.

## Visual Guidance Overlay

Laptop Bridge provides an always-on-top, click-through PySide6 instructional overlay:

- **Agent Guide Cursor**: A distinct electric cyan and slate pointer labeled "Laptop Bridge" moves smoothly from the user's current cursor position to an agent-selected target location.
- **Pulsing Target Ring**: An animated concentric target ring with crosshair ticks marks the exact element or coordinate of interest.
- **Instructional Bubble**: An optional dark glassmorphism card displays the action title and explanation.
- **Trailing Mode**: After arriving at the target and pausing, the guide cursor automatically enters trailing mode, following behind the user's real mouse cursor to assist without controlling or blocking input.
- **Click-Through**: Uses `Qt.WindowType.WindowTransparentForInput` and `WA_TransparentForMouseEvents` so the user can interact freely with apps beneath the overlay.
- **Timeout and Clear**: Guidance can specify a timeout in seconds or remain visible until explicitly cleared via `clear_guidance` or the companion tray menu.
- **Emergency Stop**: Immediately clears all visible guidance overlays across all displays.

## 60-Minute Project Coding Sessions

For coding tasks, users can grant scoped, time-limited access to specific project directories:

- **Folder Picker & Approval**: The companion provides a local folder picker and approval dialog explaining the exact permissions. Sessions expire automatically after 60 minutes.
- **MCP Coding Tools**:
  - `propose_project_session(project_path)`: Request approval for an existing project folder.
  - `project_session_status(request_id)`: Activate an approved project session and obtain its session ID.
  - `list_project_files(session_id, folder)`: List direct children inside the approved project.
  - `read_project_file(session_id, path)`: Read UTF-8 text file up to 1 MiB.
  - `write_project_file(session_id, path, content)`: Create or update UTF-8 file up to 1 MiB.
  - `apply_project_patch(session_id, patch)`: Apply unified diffs via `/usr/bin/git apply` without shell interpolation.
  - `run_project_command(session_id, argv, cwd)`: Run non-interactive commands with `shell=False`, 120s timeout, DEVNULL stdin, and 8192-byte output cap.
- **Security Boundaries**:
  - All paths and working directories are validated against the resolved project root. Path traversal (`..`) and symlink escapes pointing outside the root are strictly rejected with `PermissionError`.
  - Privilege escalation (`sudo`, `su`, `doas`) is blocked.
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
| `show_guidance` | Render click-through visual overlay and guide cursor on target display. |
| `clear_guidance` | Remove visible guidance overlays immediately. |
| `propose_project_session` | Request human approval for a 60-minute project coding session. |
| `project_session_status` | Activate approved coding session and return session token. |
| `list_project_files` | List files within the active project session root. |
| `read_project_file` | Read a file within the active project session root. |
| `write_project_file` | Write a file within the active project session root. |
| `apply_project_patch` | Apply unified diff patch inside project session with `git apply`. |
| `run_project_command` | Execute non-interactive argv command inside project root. |

## Run checks and tests

```sh
python -m compileall -q src
pytest -v
```

## macOS app bundle (developer testing)

After installing the development dependencies, build and test an unsigned local macOS app bundle:

```sh
pyinstaller --windowed --name "Laptop Bridge" --paths src -m laptop_bridge.desktop
open "dist/Laptop Bridge.app"
```

Signing and notarization are deferred for future releases.
