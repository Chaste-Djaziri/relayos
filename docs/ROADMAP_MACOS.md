# RelayOS macOS-First Implementation Roadmap
Status: Phase 01 native runtime foundation in progress (2026-10-31)
Scope: /Users/chastedjaziri/Documents/GitHub/laptop-bridge

## Product direction
RelayOS is a persistent, locally controlled macOS agent exposing approved tools to ChatGPT and other authorized MCP clients. SwiftUI/AppKit powers the menu bar, dashboard and optional notch companion. The existing Python MCP/OAuth runtime stays in place until Swift parity is proven. Windows development is frozen; do not delete its code without a separate migration decision.

## Non-negotiable security invariants
1. A tool invocation cannot approve its own permission expansion.
2. A local **Deny** must never grant anything.
3. Every command authorization binds project root, resolved executable, entire argv, working directory, and locally chosen duration.
4. A local once approval cannot become a session/persistent grant through a subsequent MCP call.
5. Historic executable-wide grants do not remain valid after migration.
6. Emergency Stop revokes active sessions, OAuth tokens and command grants, and terminates running managed process groups.
7. Untrusted file, terminal and screen contents cannot grant permissions.
8. Risky or destructive computer-use operations require a fresh user-visible decision.

## Phase 00 — Security and service reliability (current)
- [x] Review existing local Python backend and Swift companion.
- [x] Fix permission-dialog Deny handling.
- [x] Require independent local approval before project-session activation.
- [x] Save exact command approval context and locally approved duration.
- [x] Restrict reusable command grants to exact argv and cwd.
- [x] Refuse old executable-wide grants.
- [x] Wire Swift emergency stop to backend response, with error reporting.
- [x] Monitor managed commands and cancel their process group on emergency stop.
- [x] Show exact command and working directory in local permission dialog.
- [x] Run Python full test suite: 82 passed, 1 warning (Pydantic OAuth callback serialization).
- [x] Verify native Swift build and tests on the user's Mac: 4 native tests passed.
- [ ] Verify emergency stop during a real long-running process and test child process cleanup.
- [ ] Verify no capability escalation with concurrent approvals.
- [ ] Audit remaining write/patch tools and authorization-scoped endpoints.
**Pass:** 90/100 or better; every critical permission/security test must pass and no unapproved command executes.

## Phase 01 — Native runtime foundation
Refactor monolithic RelayOSApp.swift into App, Features, Services, Models, Components, and Tests. Remove development hardcoded paths. Consolidate supervisor ownership and state synchronization.
- [x] Gate helper/tunnel/approval startup on exclusive application ownership.
- [x] Extract SwiftUI views from app entry point.
- [x] Isolate the observable runtime model.
- [x] Prevent old child termination handlers from dropping new process ownership, and wait for restart shutdown.
- [x] Remove hardcoded development checkout and discover development runtime dynamically.
- [x] Expand native regression tests from one to four passing tests.
- [x] Add native `MCPHealthMonitor` using token-authenticated loopback control status instead of raw TCP port adoption.
- [x] Gate tunnel startup and external-listener adoption on authenticated MCP health.
- [x] Add `ServiceSupervisor` with bounded server/tunnel retry backoff and stale health result protection.
- [x] Pre-create local control token before MCP listener starts on fresh installations.
- [x] Verify 15 native Swift tests including opt-in authenticated live health probe; 89 Python tests pass (1 existing warning).
- [ ] Run isolated real-child crash/restart and multi-app takeover integration tests before considering Phase 01 fully complete.
- [ ] Add multi-process launch/takeover and crash-recovery integration tests.
- [x] Extract a dedicated health/recovery policy coordinator, authenticate any adopted listener, and prevent overlapping/stale health probes.
- [ ] Move remaining subprocess launch/stop implementation into the dedicated service layer.
- [x] Verify separately packaged Sprint 01 app is signed and its bundled MCP helper passes isolated authenticated loopback smoke tests.
- [ ] Verify real macOS app takeover, crash recovery, and the main app's managed server/tunnel handover on a deployed build.
**Pass:** one server/tunnel owner, predictable reconnect, no duplicate agents, successful Swift build, and comprehensive lifecycle tests.

## Phase 02 — Native UI
Implement real Dashboard, menu-bar quick panel, optional notch NSPanel, connection indicators, permission queue, activity log, and keyboard shortcuts. Support reduced motion and Macs without a notch.
**Pass:** pending approvals are visible and actionable; UI always matches backend state.

## Phase 03 — Connections and identity
Transport abstraction for ngrok and other supported secure tunnels, per-client scopes, OAuth authentication, token rotation, emergency revocation, and diagnostics.
**Pass:** approved ChatGPT tools work and revoked/unauthorized clients cannot access them.

## Phase 04 — System and storage
Add disk volumes, free/used storage, largest scoped directories, file-search and safe cleanup previews; expand CPU, memory, process and battery diagnostics.
**Pass:** accurate read-only diagnostics and no storage changes without approval.

## Phase 05 — File and coding capabilities
Scoped project operations, diff reviews, Git/build/test workflows, undo/recovery and stronger file permission checks.
**Pass:** approved project changes succeed; out-of-scope paths fail.

## Phase 06 — Managed terminal
Exact command approval, streaming output, job supervision, process trees, cancellation, limits, logs, and explicit user safety controls.
**Pass:** long-running tasks can be stopped, child processes exit, no runaway commands or permission escalation.

## Phase 07 — Computer Use
ScreenCaptureKit/Accessibility-assisted inspection, guided tasks, visible control sessions and locally approved mouse/keyboard operations.
**Pass:** authorized multi-step desktop interaction works on test apps and halts on revocation.

## Phase 08 — Task automation and system features
App management, supported macOS settings, task scheduling, Apple Shortcuts, workflow results and notifications.
**Pass:** predictable scheduled behavior and auditable approved actions.

## Phase 09 — Release readiness
Code signing, notarization, login item, update strategy, privacy permissions, crash recovery, diagnostics and CI.
**Pass:** clean-machine installation and uninstall, successful onboarding, reliable upgrade and security test suite.

## Release rubric
Security and permissions: 30
Functionality: 25
Reliability: 20
Native UX: 15
Performance and maintainability: 10

Never pass a phase with an open critical vulnerability, unverified emergency-stop behavior, or missing regression tests.

## Implementation checkpoint — 2026-10-31
- Updated local `src/laptop_bridge/state.py`: exact request context, local choice duration, scoped reusable grants, legacy grant revocation, emergency grant revocation.
- Updated local `src/laptop_bridge/server.py`: scoped authorization matching; managed command process group cancellation on Emergency Stop, timeout and bounded output.
- Updated native `RelayOSApp.swift`: explicit command details in approval UI; fail-closed backend acknowledgement for emergency-stop state.
- Updated `tests/test_project_session.py` with approval escalation and scope regression tests.
- All Python tests: **82 passed, 1 warning**. Native build: **not verified**; the execution tool blocked the request.
- Do not claim Phase 00 completed until native build and live process-tree cancellation tests pass. The running background MCP server may need a controlled restart to load these changes.

## Phase 01 checkpoint — 2026-10-31
- Atomic local commits: `39ece47`, `3c672d5`, `8231695`, `78f9c86`, `d82e30c`.
- Native Swift test suite: **4 passed, 0 failures**, with successful compilation.
- Live installed application was intentionally not replaced during these source refactors. Packaged-app handover requires a separate deployment validation.
- Changelog maintained at root `CHANGELOG.md`.

## Sprint 01 checkpoint — 2026-10-31
- Atomic commits: `789c1f5` (authenticated health monitor), `1dc69d5` (supervisor and runtime integration), `fcc3c56` (server control-token bootstrap), `e15b537` (stale-probe crash guard), `5f84c57` (live-health integration test).
- Native macOS build succeeded; 15 tests passed after the optional live health check was enabled. Python test suite: 89 passed, 1 known warning.
- Authenticated status probe against the existing MCP endpoint passed without terminating the live app.
- Signed staged bundle built successfully in `dist/relayos-sprint01/RelayOS.app`; isolated bundled MCP helper smoke-tested on a separate loopback port with unauthenticated 401 and authenticated 200, without modifying the live deployment.
- Remaining before production acceptance: real multi-instance launch/takeover and managed-process crash recovery.
- Production acceptance still requires a controlled app handover and a real managed child/tunnel recovery test; unit tests alone do not certify these.

## Dynamic command approvals and audible notifications — 2026-10-31
- [x] Expose `scope_prefix` in the MCP `authorize_project_command` API. ChatGPT may choose an immutable argv prefix, e.g. `["git","commit"]`, `["npm","install"]`, or `["npm","run","build"]` and explicitly show variable suffix arguments to the local user.
- [x] Bind local Session/Always approvals to exact project root, resolved executable, working directory and approved prefix; Once stays a single exact argv invocation.
- [x] Deny overly broad prefixes (single token) and interpreter/shell delegation. Require a fresh local decision when the client alters the proposed prefix.
- [x] Preserve existing `git add` saved permissions and support dynamic prefixes across database/helper restarts with explicit revocation.
- [x] Play a native sound once when a new command or MCP client approval arrives, with a default-on Settings toggle.
- [x] Run Python tests: 97 passed, 1 existing Pydantic warning; native Swift: 16 passed.
- [ ] Build the signed app and complete a real handover/connection-recovery check.
- [ ] Confirm the new bundled MCP tool schema exposes `scope_prefix` and validate a two-command live reuse test after deployment.

## Native Permissions Center — 2026-10-31

- [x] Expose local helper commands to list and revoke reusable command-grant records without extending the remote authorization API.
- [x] Add native Command Permissions navigation and searchable grants (project, cwd, executable, approved prefix, duration and expiration).
- [x] Require confirmation before local revocation; scope changes must be reviewed as new approvals rather than silently broadened.
- [x] Preserve existing persistent folder-permissions management.
- [x] Verify backend test suite: 99 passed, one existing Pydantic serialization warning.
- [x] Verify native test suite: 18 passed, zero failures.
- [ ] Build signed staging bundle and run isolated packaged-helper smoke tests.
- [ ] Deploy via controlled handover and verify list/revoke UI against real grant data.

## Approval scope visibility and final permissions deployment — 2026-10-31

- [x] Automatic locally reviewable prefix suggestions when an MCP caller omits scope_prefix, including git commit, git log, npm install, npm run build, and Swift test/build.
- [x] Preserve exact-argument restrictions for unsafe shell/interpreter and ambiguous command forms; no legacy exact-command grant is silently widened.
- [x] Replace internal project_command dialog title with a human-readable executable or proposed reusable prefix.
- [x] Make the Command Permissions view available both as a dedicated sidebar item and directly within Tools & permissions.
- [x] Verify Python: 101 passed, one existing serialization warning; Swift: 18 passed.
- [ ] Verify signed packaged app and isolated bundled MCP helper.
- [ ] Deploy the new signed app to dist/RelayOS.app with rollback and confirm single native/MCP/tunnel process ownership.
- [ ] Run a real two-message git commit prefix-reuse test without making a commit as part of the test (authorization lookup only).
- [ ] Verify permissions listing in the running native UI. Avoid revoking an existing user grant without explicit selection.

## Saved-command permission deduplication and compact UI — 2026-10-31

- [x] Inspect existing saved approvals: multiple grants share executable labels, but older exact argv are retained only as hashes and must not be automatically merged by executable.
- [x] Prevent repeat local approvals for the same complete effective scope from creating new saved records. Preserve one-time tokens as unique.
- [x] Add local-only duplicate preview and confirmed cleanup; keep the newest per exact project, executable, cwd, duration, session, and command scope. Never broaden, silently purge or conflate differing exact commands.
- [x] Add privacy-preserving short fingerprints for legacy exact approvals without disclosing original argv.
- [x] Group permissions by executable and project in a compact expandable native list; expose duplicate count and a confirmation-required cleanup control.
- [x] Run Python tests: 104 passed with one pre-existing Pydantic warning; native Swift tests: 18 passed.
- [ ] Build, sign and smoke-test an isolated staging bundle.
- [ ] Controlled handover, live permissions listing, and process ownership verification.
- [ ] Verify the native UI duplicate preview and cleanup flow interactively. Do not delete stored grants without the user's local confirmation.

## Sprint 02 — Runtime reliability & connection recovery (2026-10-31)

- [x] Authenticated public MCP tunnel probe checks ngrok's local inspector and verifies a remote unauthenticated HTTP 401, distinguishing a live ngrok PID from a working public endpoint.
- [x] Validate ngrok forwards specifically to the RelayOS localhost MCP listener before adopting its URL. Repeatedly discover a tunnel instead of relying on a single inspector timer or parsing arbitrary subprocess logs.
- [x] Add independent bounded retries for unresponsive app-owned MCP and ngrok processes, suppress overlapping and stale health checks, and leave unrelated listeners alone.
- [x] Display local MCP health and verified public tunnel status separately in menu bar/General/ngrok screens, with a visible recovery notice.
- [x] Extract hardened single-instance flock lease; reject symlink/foreign/insecure lock files, prevent simultaneous lock owners, and test release/reacquisition.
- [x] Verify isolated packaged MCP helper survives a forced child crash and rebinds its own temporary port with existing local control token.
- [x] Test a real managed child termination/replacement slot race without touching the production MCP server.
- [x] Native Swift unit tests and complete Python suite passed (104 Python tests, one pre-existing Pydantic warning).
- [ ] Validate signed staged bundle, packaged helper recovery and controlled rollout with rollback.
- [ ] Live app-owned ngrok/MCP crash injection (would interrupt active ChatGPT connection); test only after controlled deployment.
- [ ] Full native app SIGKILL/orphan-child recovery, and zero-downtime tunnel continuity. The app currently owns ngrok, so restarting it necessarily causes a brief tunnel interruption; true zero-downtime handover requires a separately persistent edge/tunnel supervisor.

## Sprint 03 — Native Approval Inbox and Activity History (2026-10-31)

- [x] Unified local approval inbox merges project command, project session and MCP OAuth connection requests without exposing an authorization API remotely.
- [x] Present all pending requests in a native nonblocking Approval Center with Once/Session/Always/Deny; OAuth connection approvals only permit Approve/Deny.
- [x] Retain explicit backend expiry checks, one-time decisions, and fail-closed emergency-stop handling. Tests cover multiple requests and already decided/expired IDs.
- [x] Replace blocking NSAlert polling with a deduplicated, bounded arrival tracker, existing approval sound, opt-in macOS notifications without sensitive command details, and a menu bar pending count.
- [x] Add a searchable persisted metadata-only audit feed for requests, approvals, denials, expirations, executed actions and recorded outcomes; show registered OAuth client names without OAuth redirect URIs.
- [x] Remove development-only path assumption from native permission grant refresh and avoid helper output-pipe deadlock for larger inboxes.
- [x] Python suite: 109 passed; one pre-existing Pydantic serializer warning. Native Swift compilation/tests passed including inbox model and notification dedup tests.
- [ ] Validate signed staging build and isolated packaged MCP start/restart smoke tests.
- [ ] Preserve backup, perform controlled native handover and verify live MCP health and single-instance ownership.
- [ ] Validate system notification permission prompt, audible output and multi-request inbox visually on the user's desktop; automatic tests cannot establish actual presentation.

## Sprint 04 — Advanced Terminal & Coding Sessions (2026-10-31)

- [x] Add opt-in background commands with the existing approved project/cwd/executable/argument authorization gate. Existing synchronous `run_project_command` behavior is unchanged.
- [x] Expose start/list/read/cancel MCP tools constrained to an active approved coding session. Read uses per-stream offsets and max 8 KiB per poll, no shell.
- [x] Persist metadata-only job history in SQLite (project, executable basename, status, timing, exit code); do not retain raw command argv or output in database.
- [x] Enforce max four active jobs per MCP runtime, 4 MiB per-output-stream limits, bounded runtime, session expiration checks, emergency-stop and explicit cancellation with owned process-tree cleanup.
- [x] Add authenticated local-loopback output retrieval for the native companion plus local-only CLI list/cancel commands.
- [x] Add native Terminal Jobs screen with running/completed states, project and executable filtering, incremental output, and Cancel.
- [x] Mark unfinished metadata as interrupted upon MCP server restart; historical job output is ephemeral and not reattached to an unrelated process.
- [x] Test exact authorization and one-use consumption, output offsets, session isolation, cancellation, emergency stop, orphan marking, and authenticated local output endpoint.
- [x] Run Python suite (116 passed, one pre-existing Pydantic warning) and native Swift suite (passed).
- [ ] Verify signed staging bundle, isolated packaged MCP startup/restart, rollback copy and live handover.
- [ ] Visually verify native task progress and cancellation using a harmless locally approved test job.
- [ ] Future: independent job supervisor that can positively reap orphan children after an abrupt native/server SIGKILL and optionally reattach output. Current jobs are process-owned and not restart-persistent.

## UI modernization sprint — 2026-10-31
- [x] Organize native settings navigation into meaningful sections with branded sidebar header.
- [x] Add persisted System, Light and Dark appearance selection using native SwiftUI color schemes.
- [x] Improve settings detail typography and centered width/spacing, retaining existing security actions and screens.
- [x] Run Swift native compilation and tests.
- [ ] Validate appearance contrast, scrolling and layouts in the staged running UI at different window sizes.
- [ ] Signed staging build, isolate packaged helper tests, protected handover and visual acceptance.
- [ ] Further refine secondary panels into consistent reusable settings rows and cards after visual inspection.

## Appearance improvements — 2026-10-31
- [x] Dedicated Appearance sidebar page and visual mode previews.
- [x] Persist mode, accent, UI font size, reduced-motion preference and sidebar-translucency preference.
- [x] Apply appearance and accent to main window, Settings and menu bar; apply UI text scaling to main window.
- [x] Swift compilation and native regression suite pass.
- [ ] Wire advanced reduce-motion and sidebar translucency preferences to every relevant native UI animation/material; currently stored only.
- [ ] Stage signed bundle, verify and deploy with rollback; visually inspect light/dark and control contrast.

## Window-first desktop completion — 2026-11-01
- [x] W01: closing Settings no longer quits RelayOS; explicit Quit retains control.
- [x] W01: managed child-process waits no longer block the UI during restarts, including emergency-stop acknowledgement.
- [x] W01: trust only a known configured HTTPS /mcp endpoint for fallback public HTTP 401 verification when ngrok inspector is unavailable; do not kill unowned tunnel processes.
- [x] W02: build a separate floating native permission guide with drag-enabled signed application icon, Reveal in Finder, and privacy settings links.
- [x] W02: remove unreliable Full Disk Access inference; refresh checkable screen recording, accessibility and notification statuses when returning from System Settings.
- [x] W03: confirm individual and bulk folder revocations and do their helper calls off the UI thread; do not restart ngrok when saving tool capabilities.
- [x] W03: correct OAuth grant labels, add sidebar keyword search and respect system/user reduced-motion preferences in shared components.
- [x] W04: modern four-step first-run setup with product previews, optional permission setup, ngrok token input and resume step persistence.
- [x] W05: add inert light/dark component previews that do not initialize or manipulate the live MCP runtime.
- [x] Native Swift test/build checks pass before release staging.
- [ ] Verify real permission guide drag/drop acceptance on the installed macOS version; Finder Add remains the supported fallback.
- [ ] Validate light/dark, reduced-motion, window-size clipping, hover, keyboard navigation and VoiceOver interactively.
- [ ] Add fully inert mock data model and previews for every data-driven page, including pending approval and terminal output cases.
- [ ] Test complete onboarding on a fresh profile without changing existing OAuth tokens.
- [ ] Validate exact ngrok handover/health fallback live, signed bundle and regression tests without killing the current connector.
- [ ] Finish W06 staged release validation, rollback backup, controlled install and single-owner health checks.
- [ ] Independently supervised process reaping after native app SIGKILL remains a future hardening item.

## Xcode ownership and Swift migration — 2026-11-01
- [x] Add native macOS XcodeGen project specification under `Native/LaptopBridgeApp/project.yml`.
- [x] Generate `RelayOS.xcodeproj` with Release app identity `rw.shangazi.relayos` and isolated Debug identity `rw.shangazi.relayos.dev`.
- [x] Add safe Debug-only UI showcase and retain existing `#Preview` fixtures without starting the production MCP service.
- [x] Keep SwiftPM regression tests passing and document signing workflows.
- [ ] Validate native `xcodebuild` Debug target and test scheme end to end.
- [ ] Configure a real Apple Development team/certificate in Xcode and verify signature stability between builds.
- [ ] Port Python server, OAuth and approval state to tested Swift modules before removing bundled Python runtime.
- [ ] Integrate final Swift helper packaging, Developer ID signing, notarization and staged installation.
