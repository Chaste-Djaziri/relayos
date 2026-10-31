# RelayOS macOS-First Implementation Roadmap
Status: In progress — Phase 00 security foundation
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
- [x] Run Python full test suite: 82 passed, 1 warning (Pydantic OAuth callback serialization).\n- [ ] Run native Swift build successfully on the user's Mac (tool execution was blocked; not verified).
- [ ] Verify emergency stop during a real long-running process and test child process cleanup.
- [ ] Verify no capability escalation with concurrent approvals.
- [ ] Audit remaining write/patch tools and authorization-scoped endpoints.
**Pass:** 90/100 or better; every critical permission/security test must pass and no unapproved command executes.

## Phase 01 — Native runtime foundation
Refactor monolithic RelayOSApp.swift into App, Features, Services, Models, Components, and Tests. Remove development hardcoded paths. Consolidate supervisor ownership and state synchronization.
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
