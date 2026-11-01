<!-- Path: docs/SCREEN_CAPTURE_SHARING.md -->
# RelayOS on-demand screen sharing with ChatGPT

**Status:** Implemented in the development branch; not installed or visually
validated on the user's signed macOS production app.

This is **single-frame sharing**, not remote desktop control, hidden recording,
or continuous video streaming. ChatGPT can request one capture of:

- `app`: an open application by exact name (e.g. Safari) or bundle identifier;
  its visible windows are isolated from other applications.
- `window`: an on-screen window by exact title or numeric window ID. Ambiguous
  titles are rejected rather than capturing an arbitrary window.
- `display`: a specific macOS display ID, or `main` for the primary monitor.

## Authorization and delivery

1. Enable **Screen Guidance** under RelayOS capabilities and restart its MCP
   service so the newly enabled tools are advertised. Existing permissions to
   run project commands or connect the MCP client **never grant screen access**.
2. ChatGPT calls `request_screen_capture(scope, target)`. RelayOS queues a
   local `screen_capture` request with the exact scope and target. At this step
   no image is captured.
3. The local user sees an Approval Inbox entry with the target and selects
   **Once** or **Deny**. Session/Always cannot authorize screenshots.
4. If macOS has not granted Screen & System Audio Recording permission, the
   capture helper requests the OS permission **only at the approved capture**.
   macOS may require restarting RelayOS for the permission to take effect.
5. ChatGPT calls `capture_approved_screen(request_id)`. The single-use
   authorization is atomically consumed. A separate signed ScreenCaptureKit
   executable selects the requested app/window/display and captures one frame.
   The JPEG is bounded to 1600px width and 4 MB and returned as MCP
   `ImageContent` for ChatGPT to inspect.
6. There is **no continuous stream**, background interval capture or audio.
   A second screenshot, including one of the same app, requires a new locally
   approved request. The screenshot is passed through process memory, not
   written to an image file. Only metadata (scope/target/timing) enters the
   persistent audit history.

Emergency Stop blocks the capture. Pending approvals expire after five
minutes, and denying an approval cannot be bypassed. Once-used request tokens
cannot be replayed. The MCP listener removes the legacy ungated snapshot
tools from its published tool list.

## Files

- `Native/LaptopBridgeApp/ScreenCapture/RelayOSScreenCapture.swift` —
  native ScreenCaptureKit image capture; separate Swift Package executable.
- `src/laptop_bridge/screen_capture.py` — policy, local authorization
  enforcement, helper invocation and size/content validation.
- `src/laptop_bridge/server.py` — MCP request and image-response tools.
- `Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Views/Pages/ApprovalsPageView.swift`
  and `Views/QuickPanel/NotchPanel.swift` — local Once/Deny controls.
- `scripts/build_relayos_app.sh` — embeds the helper with the bundled server.
- `tests/test_screen_capture.py` — isolated Python authorization tests.

## Remaining manual QA

- Test the signed release app with the selected app, window and both internal
  and external displays; verify exact content and protected-window behavior.
- Verify that Apple's permission prompt targets the correct app identity and
  regrant/restart steps work after updating the signed application.
- Verify MCP clients render image blocks from the installed bundle; current
  Swift and Python unit tests do not demonstrate a real desktop capture.
- Later continuous sharing, automatic refresh sessions and interactive computer
  control require a separate explicit design and authorization model.
