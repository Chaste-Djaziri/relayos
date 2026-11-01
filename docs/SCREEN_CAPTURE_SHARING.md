<!-- Path: docs/SCREEN_CAPTURE_SHARING.md -->
# RelayOS on-demand screen sharing with ChatGPT

**Status:** Signed hybrid app installed at `/Applications/RelayOS.app` on
2026-11-01 after isolated MCP smoke checks and a rollback-backed handover.
The installed app still uses the prior capture implementation. The new
short-lived HTTPS retrieval fallback is **source-only** pending a signed
redeployment and a live visual acceptance test. The screen-sharing capability
remains off until enabled locally, and an actual consented screenshot has
**not** yet been visually validated in ChatGPT.

This is **single-frame sharing**, not remote desktop control, hidden recording,
or continuous video streaming. ChatGPT can request one capture of:

- `app`: an open application by exact name (e.g. Safari) or bundle identifier;
  its visible windows are isolated from other applications.
- `window`: an on-screen window by exact title or numeric window ID. Ambiguous
  titles are rejected rather than capturing an arbitrary window.
- `display`: a specific macOS display ID, or `main` for the primary monitor.

## Authorization and delivery

1. In RelayOS, open **Tools & permissions** and enable **On-demand screen sharing**.
   Click **Save tool settings**. RelayOS reloads the MCP service while keeping
   the configured ngrok tunnel. Reconnect the ChatGPT RelayOS connector to
   discover the two new tools. Existing project or connection permissions
   **never grant screen access**.
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
   `ImageContent` **and**, if a public HTTPS origin is configured, the
   metadata contains `image_url`, `image_url_expires_in_seconds`, and
   `image_url_max_downloads`.
6. If the MCP connector omits image content, ChatGPT may fetch the returned
   HTTPS `image_url` through RelayOS's existing public tunnel. The GET route
   `/screenshots/{token}` returns JPEG bytes and does not require an OAuth
   bearer token: the high-entropy URL itself is a **bearer secret**. Keep it
   private. It expires after **120 seconds or three downloads**, whichever
   comes first. Use the link promptly; some image previewers consume a read.
7. There is **no continuous stream**, background interval capture or audio.
   A second screenshot, including one of the same app, requires a new locally
   approved request. The screenshot is held only in a bounded in-process
   memory store (at most four images), not written to an image file or cloud
   storage. HTTP responses use `no-store`, no-referrer and no-index headers;
   expired images are discarded on access or at the next capture. Emergency
   Stop revokes all images immediately, and restarting RelayOS clears them.
   Only metadata (scope/target/timing) enters persistent audit history; bearer
   URLs and image content are not persisted. Without a configured public HTTPS
   origin, the original MCP image response remains available and no link is
   minted.

Emergency Stop blocks the capture. Pending approvals expire after five
minutes, and denying an approval cannot be bypassed. Once-used request tokens
cannot be replayed. The MCP listener removes the legacy ungated snapshot
tools from its published tool list.

## Files

- `Native/LaptopBridgeApp/ScreenCapture/RelayOSScreenCapture.swift` —
  native ScreenCaptureKit image capture; separate Swift Package executable.
- `src/laptop_bridge/screen_capture.py` — policy, local authorization
  enforcement, helper invocation and size/content validation.
- `src/laptop_bridge/server.py` — MCP request, image-response tools and
  ephemeral HTTP retrieval route.
- `src/laptop_bridge/screenshot_links.py` — memory-only expiring token store,
  bounded downloads and immediate revocation.
- `Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Views/Pages/ApprovalsPageView.swift`
  and `Views/QuickPanel/NotchPanel.swift` — local Once/Deny controls.
- `scripts/build_relayos_app.sh` — embeds the helper with the bundled server.
- `tests/test_screen_capture.py` — isolated Python authorization tests.
- `tests/test_screenshot_links.py` — URL issuance, expiry, one-time capture
  integration, HTTP no-store response and Emergency Stop regression tests.

## Point-at-item cursor guidance (source implementation)

After an approved **display screenshot** lets ChatGPT identify a target,
`point_screen_target(x, y, display="main", hold_seconds=20)` moves the
existing equilateral RelayOS virtual cursor toward the normalized target
(0..1, origin **top-left** of the *full display screenshot*) and smoothly
rotates its tip toward the item. It stops approximately 46 macOS screen
points away from the item, then stays there. Once the real mouse enters a
64-point radius around the target **from outside**, the guide returns to
following the mouse. It also returns after timeout (1–60 seconds, default 20)
or `clear_screen_pointer`, and immediately on Emergency Stop. When the
mouse already starts near the target, it must leave and re-enter the radius
to dismiss guidance.

The native app polls an authenticated loopback-only
`GET /control/cursor-guidance`, then acknowledges arrival with
`POST /control/cursor-guidance/arrived` bound to a target ID. The public
MCP tool can only set a temporary visual target; it **never moves or clicks
the real macOS pointer**, injects input or triggers a new capture. This
feature remains source-only until the Swift app is rebuilt and deployed.

## Remaining manual QA

- Test the signed release app with the selected app, window and both internal
  and external displays; verify exact content and protected-window behavior.
- Verify that Apple's permission prompt targets the correct app identity and
  regrant/restart steps work after updating the signed application.
- Verify ChatGPT can **open an actual approved screenshot URL** over the
  connected ngrok tunnel and visually inspect the JPEG. The unit tests cover
  in-memory delivery, not the installed-app public path; do not claim success
  until a real approved screenshot is received.
- Later continuous sharing, automatic refresh sessions and interactive computer
  control require a separate explicit design and authorization model.
