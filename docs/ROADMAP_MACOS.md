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
