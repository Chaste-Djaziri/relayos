# RelayOS Teaching Notepad & Guided Lessons

## Scope and design
The macOS app now contains an interactive floating **Teaching Notepad**. It
is a native `NSPanel` above other apps, with a movable title bar, resizable
frame, horizontal/vertical scrolling, Clear and Hide actions. The canvas has
a fixed 1000 × 1200 logical drawing surface; the visible viewport moves
independently. Its appearance is controlled by authenticated MCP tools.

The backend is the bundled Python MCP service and is **local to this Mac**.
A token-protected loopback endpoint provides the canvas snapshot to SwiftUI.
The public MCP connection can open a board, draw primitives, read state and
remove individual elements, but cannot execute arbitrary code from the board.
The board lives in memory, has an expiry (maximum one hour), and is never
saved as a file or chat transcript.

## MCP tools

- `open_guidance_notepad(title, duration_seconds)` creates a board.
- `draw_guidance_notepad(board_id, elements)` adds up to 30 text, code,
  rectangle, ellipse, line, arrow or polyline objects per call.
- `edit_guidance_notepad(board_id, action, element_ids?)` supports
  show, hide, clear, remove and close.
- `guidance_notepad_status()` lists elements and their IDs.
- `propose_guided_lesson(goal, steps, duration_seconds)` requests explicit
  macOS **Approve Once** consent to collect action-event metadata for a
  bounded teaching session. The user can deny in the approval inbox.
- `activate_guided_lesson(request_id)` starts a plan after local approval.
- `guided_lesson_progress()` and `guided_lesson_activity(session_id, ...)`
  expose the step index and bounded event metadata.
- `stop_guided_lesson(session_id)` stops the observer immediately.

Example drawing (the board ID comes from the first tool):
```json
[
  {"kind": "code", "x": 0.07, "y": 0.08, "w": 0.8,
   "text": "name = input('Your name:')\nprint(f'Hello {name}')",
   "color": "green", "font_size": 21},
  {"kind": "ellipse", "x": 0.06, "y": 0.30, "w": 0.64, "h": 0.12,
   "color": "orange", "stroke_width": 4},
  {"kind": "arrow", "x": 0.72, "y": 0.28, "w": 0.17, "h": 0.08,
   "color": "accent"}
]
```

## Pre-authored lesson steps
Example plan:
```json
[
  {"instruction":"Open Visual Studio Code.",
   "verify":{"kind":"app_active","bundle_id":"com.microsoft.VSCode"}},
  {"instruction":"Scroll through the Explorer sidebar.",
   "verify":{"kind":"scroll","bundle_id":"com.microsoft.VSCode"}},
  {"instruction":"Create a hello.py file and show me your code.",
   "verify":{"kind":"manual"},
   "notes":"print('Hello, world!')"}
]
```

The native app polls current lesson status approximately once per second,
installs event monitors **only while the approved session is active**, and
posts metadata through the authenticated localhost control API. Supported
signals are app-active (foreground bundle ID), click (optionally normalized
display coordinates), scroll occurrence, and typing occurrence. A local
manual Done control can advance a human-verified step. A Pause button removes
input monitors until resumed. Stop, expiry, service failure, Screen Guidance
revocation and Emergency Stop all terminate observation.

No typed character, input/field value, clipboard, file content or window
title is acquired by this observer. It does not record screenshots. Keys are
not replayed, the real pointer does not move, and no apps are opened by the
lesson engine. Event retention is in-memory only, at most the last 300
events; only 40 steps and a 60-minute duration are permitted.

**Verification limitation:** a scroll event means the user scrolled, not
that a requested document was read. Likewise, typing occurrence is not a
test of code correctness, and a click does not prove the right control was
clicked. For these tasks use manual acknowledgement, or a new permitted
screen capture and ChatGPT reasoning. Sensitive screens may be visible in
screen captures, so each capture retains the existing separate permission
workflow.

## ChatGPT orchestration boundary

An MCP plugin is **request-response**: it does not independently wake up
ChatGPT, access the user's screen forever or post fresh chat turns. The
new native observer can advance *pre-authored, locally verifiable steps*
after the user's first message, including notepad and cursor-tip updates.
A genuinely adaptive Python tutor that sees new code, analyzes screenshots,
generates exercises and continuously chooses next steps requires a separate
**local agent loop** using an explicitly configured model provider/API and
new user-consented screen/file scopes. This has **not** been implemented;
do not claim that it is running just because the MCP plugin is connected.

The client may need to reconnect or refresh RelayOS to discover newly
packaged MCP tools after a signed deployment. Changing source files alone
does not update the running plugin.
