<!-- Path: docs/TERMINAL_JOB_MONITORING.md -->
# RelayOS — terminal job monitoring and progress

## How it works

The Python MCP server remains responsible for running locally approved commands.
It runs commands directly (no shell), with at most four concurrent jobs, a
600-second default timeout and bounded temporary stdout/stderr buffers. It
stores job lifecycle metadata separately, including queued, running, completed,
failed, cancelled, timed out, output-limited and interrupted states.

The SwiftUI app now monitors jobs from launch rather than polling only when the
Terminal Jobs screen is visible. It asks the authenticated loopback control API
for the most recent 100 jobs every two seconds and fetches incremental output for
the selected job using byte offsets. It never automatically approves or launches
commands.

### Native UI

- Settings → **Terminal jobs** lists recent jobs, running/queued counts, execution
  state, working directory, error reason and cancellation requests.
- Click **View Output** to follow stdout and stderr automatically. Turn
  **Follow output** off to inspect older lines without being scrolled to the end.
- The console displays elapsed runtime and streamed byte counts. A progress
  percentage appears **only** if the command itself prints a percentage; an
  indeterminate indicator is shown for other running commands.
- Enable **Notify when a job finishes** to request macOS notifications for
  active-to-completed/failed/cancelled transitions. It defaults to off. No
  commands, file paths or terminal output appear in the notification body.
- The menu-bar panel, notch panel, sidebar badge and main Settings top bar expose
  active jobs and a shortcut to the live console.
- **Cancel** asks the Python job manager to terminate an owned job. It is
  unavailable in an observe-only Xcode development client.
- The console buffers only the most recent 80,000 characters. Python caps each
  output stream at four MiB. Output from a previous MCP process is unavailable
  after a server restart; metadata is retained with an interrupted status.

### Local control API

The companion uses the same restricted local control token as RelayOS health
checks:

- `GET /control/command-jobs?limit=100`: current persisted job list.
- `GET /control/command-job-output/{id}?stdout_offset=0&stderr_offset=0`:
  bounded incremental output and updated byte offsets.
- `POST /control/command-jobs/cancel`: locally request cancellation, body
  `{"job_id": "<id>"}`.

All of these routes require `x-relayos-control-token`. The cancellation route
does **not** approve a new command or allow the caller to execute one. Existing
MCP session-scoped job tools and approval rules remain in place. Older installed
bundles without the list/cancel control routes are supported via the existing
bundled local approvals helper when the new route returns HTTP 404.

## Validation

- Python isolation tests: approval before launch, one-time grant, incremental
  output, session isolation, termination/cancellation, Emergency Stop,
  interrupted metadata after restart, control authentication, and listing/cancel
  endpoints. These run against a temporary test database, not live jobs.
- Swift tests: job list decoding, offset handling, reported-percentage parsing,
  duration, bounded output, and notebook UI models.
- `swift test --package-path Native/LaptopBridgeApp`
- `xcodebuild -project Native/LaptopBridgeApp/RelayOS.xcodeproj -scheme RelayOS -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
- `.venv/bin/pytest -q`

## Manual acceptance in a staged bundle

1. Start a disposable project job through RelayOS's existing approved MCP job
   tool; use a command that emits several lines with a short delay.
2. Open the menu-bar panel or notch view: the active job count should update
   without opening Terminal Jobs first.
3. Open Terminal Jobs, select the new job, and verify incremental stdout/stderr,
   elapsed runtime and autoscroll. Turn **Follow output** off and on.
4. Use an explicit progress-printing test command to verify that its reported
   percentage is displayed; verify a command without percentages does not
   invent one.
5. Start a second approved, long-lived test job and cancel it through the native
   UI; confirm the Python manager terminates the owned process and the job
   becomes cancelled.
6. Close Settings and reopen it: monitoring should continue while RelayOS
   remains running. Verify finish notifications only if enabled.
7. Restart only the **isolated test** MCP server and confirm old running test
   jobs become interrupted with output-unavailable state.
8. Check light/dark mode, selection changes, errors on disconnect, and no command
   execution without a local approval.

**Do not stop or replace the installed production app to perform these tests.**
All source and build checks in this change are isolated; actual manual viewing
and cancellation in the installed bundle require a separately approved deployment.
