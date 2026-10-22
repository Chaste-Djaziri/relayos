# Laptop Bridge — v0.4 Native macOS App

**Status: local macOS app prototype.** Python 3.11+. The click-launched PySide6 app starts and supervises the local MCP server, exposes ChatGPT-facing action metadata, renders a transparent click-through overlay with a smooth triangular guide cursor, captures the active display only on request, retains metadata-only history for 30 days, and offers an emergency stop.

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

To create a Finder-launchable app, run `./scripts/build_macos_app.sh` and open `dist/Laptop Bridge.app`.

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

The write and command tools expose MCP annotations so ChatGPT can request confirmation in chat. Clients without MCP elicitation support fall back to the local companion dialog.

## Follow-ups and reminders

`record_follow_up_request`, `list_pending_follow_ups`, and `complete_follow_up` retain only a title, schedule, expiration, project-session reference, and metadata. After recording one, ask ChatGPT to schedule a reminder or recurring task using the returned ID. The MCP server cannot create a ChatGPT heartbeat autonomously for every account; scheduling remains a ChatGPT/workspace feature.

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
| `start_guidance_session` | Start an explicit, bounded visual guidance session. |
| `guidance_session_status` | Read the active guidance session and expiry. |
| `refresh_guidance_screen` | Capture one current display frame for an active session. |
| `get_guidance_events` | Poll passive click metadata from an active session. |
| `stop_guidance_session` | Stop sharing and clear the guidance session. |
| `show_guidance` | Render click-through visual overlay and guide cursor on target display. |
| `clear_guidance` | Remove visible guidance overlays immediately. |
| `propose_project_session` | Request human approval for a 60-minute project coding session. |
| `project_session_status` | Activate approved coding session and return session token. |
| `list_project_files` | List files within the active project session root. |
| `read_project_file` | Read a file within the active project session root. |
| `write_project_file` | Write a file within the active project session root. |
| `apply_project_patch` | Apply unified diff patch inside project session with `git apply`. |
| `run_project_command` | Execute non-interactive argv command inside project root. |
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
