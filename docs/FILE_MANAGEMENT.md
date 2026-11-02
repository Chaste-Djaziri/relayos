# Path: docs/FILE_MANAGEMENT.md
# RelayOS File & App Management (macOS)

## Permission model

File management is NOT a general arbitrary filesystem or shell privilege. ChatGPT requests an **exact folder** using `propose_file_manager_access(folder)`, and the person must select **Approve Once** in the native RelayOS inbox. ChatGPT then calls `activate_file_manager_access(request_id)` to obtain a 15-minute session, scoped to the approved directory.

A session allows bounded metadata-only listing, filename search, file/folder details, app bundle inspection and CLI tool inventory. It does not read arbitrary file contents, expose secret values or automatically alter files. `revoke_file_manager_access(session_id)` and Emergency Stop immediately revoke the session.

### Read-only tools

- `managed_list_directory(session_id, folder, offset, limit, show_hidden)` — 100 items per page, capped listing.
- `managed_item_details(session_id, path)` — type, modification/creation times, logical file size, app bundle/version where available.
- `managed_find_items(session_id, query, limit)` — bounded filename search; skips common sensitive directories and symlinks.
- `managed_installed_apps(session_id, offset, limit)` — catalog apps inside the approved Applications folder(s). To see /Applications, explicitly approve /Applications.
- `managed_developer_tools(session_id)` — hardcoded common CLI tool paths, never runs them.
- `managed_trash_preview()` — number of entries seen in home Trash, not a full all-volume inventory.

### File changes

`propose_file_operation(session_id, action, paths, destination)` supports:

- `trash` — move up to 10 explicitly selected items through macOS's native Trash API; does not permanently delete them.
- `move` and `rename` — move one item, never replace an existing destination.
- `copy` — copy a selected file/folder with preflight caps (200 MiB / 2000 entries) and no symbolic-link traversal.
- `mkdir` — create one new subfolder inside the approved root.

Every proposal produces a **new, non-reusable, local Once/Deny approval request** showing exact paths. Only afterward may ChatGPT call `execute_approved_file_operation(request_id)`. The server rechecks the session, canonical paths, source file identities and destination state. Each attempt is auditable. Partial Trash successes and failures are reported explicitly.

Important limits: system folders, RelayOS's own app/state, protected credentials, symlinks, top-level user folders and directories containing Git repositories or credential-like files cannot be trashed through this interface. GitHub recoverability, ignored work, local databases and credentials must be verified independently. RelayOS cannot promise a project is backed up merely because .git exists.

### Permanently emptying Trash

`propose_empty_trash()` creates a distinct approval request. The native approval UI displays an **irreversible all-volume warning** and requires the local person to type **EMPTY TRASH**, then Approve Once. `execute_approved_empty_trash(request_id)` asks Finder to empty ALL Trash, which also affects files that RelayOS never moved. This requires macOS Finder Automation consent; failure is reported rather than ignored.

There is **no permanent-delete-file API**, no always-allow permission for file mutations, no automatic cleanup and no silent Trash emptying. A user can revoke, deny or Emergency Stop at any point. Finder Trash may contain items not visible in the home Trash preview.

### App and package management

Native .app bundles can be inspected in /Applications or ~/Applications, and non-system apps can be moved to Trash after local approval. This is not guaranteed to uninstall associated support files, login items, licenses or running services. CLI packages can be inventoried, but should be removed through their package manager, not by unlinking a binary; package uninstall is not yet exposed.

### Verification

Run Python unit tests for `tests/test_file_management.py` and Swift tests. Build the signed hybrid application, run an isolated packaged MCP smoke test, verify its new tool discovery and the macOS Trash API, then deploy with the existing rollback/handover workflow. Refresh the ChatGPT RelayOS plugin after the updated MCP helper is running.
