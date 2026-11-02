<!-- Path: docs/SCREEN_CAPTURE_SHARING.md -->
# RelayOS on-demand screen sharing with ChatGPT

**Status:** Existing on-demand screenshot sharing has been tested with
ChatGPT on a signed RelayOS installation. The optional, time-bounded
main-display sharing session documented below is implemented in source and
must be deployed as a new signed app before it becomes available.

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
3. **Default:** the local user sees an Approval Inbox entry with the exact
   target and selects **Once** or **Deny**; Session/Always decisions in the
   generic inbox still cannot authorize screenshots. **Optional:** if the user
   explicitly starts a time-bounded main-display sharing session in RelayOS,
   repeated requests for `display:main` are instantly authorized with
   independently consumable IDs, and no per-frame inbox prompt appears.
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
   Every screenshot needs a fresh request ID; the separate local Once
   decision is skipped only for `display:main` while a user-enabled sharing
   session is active. The screenshot is held only in a bounded in-process
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

## One-click main-display sharing (optional; 30 minutes)

**Default is OFF.** In the signed RelayOS app, open the macOS menu-bar
control center (or **Settings → Security**), then press
**Share main display · 30 min**. This is an explicit decision made in
the native Mac UI, not a permission ChatGPT or an MCP request can grant.

During the session, `request_screen_capture(scope="display", target="")`
returns `permission="active_sharing_session"`. ChatGPT can immediately
use the returned one-time request ID with `capture_approved_screen`
without another local prompt. No capture happens until that second tool
call. **Named apps, windows and external displays** continue to require
the normal local Approve Once confirmation.

The always-visible RelayOS menu-bar indicator marks an active session.
The local control interface shows an approximate countdown. **Stop sharing**
revokes the session immediately. The session also stops after 30 minutes,
on server restart, when Screen Guidance is disabled, or with Emergency Stop.
An in-flight capture cannot deliver its image if sharing stops before the
image is returned. Stopping also revokes outstanding temporary image links.
A new session does not reactivate expired requests.
Each frame remains a separately audited, single-use capture. The session
exists only in the MCP server's memory, with no persistent Always-allow
screen grant or background capture loop.

This convenience mode does not override macOS's **Screen & System Audio
Recording** permission for the signed RelayOS capture helper. It affects
only RelayOS's own repeated approval prompts.

**Local control contract:** the token-authenticated
`GET /control/screen-sharing` reports active status and remaining seconds,
and `POST /control/screen-sharing` accepts
`{"enabled":true,"duration_seconds":1800}` or
`{"enabled":false}`, invoked by the native UI. The server enforces
60–3600 seconds per activation. No public MCP tool can start a session.

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

## Animated shape highlights (development source only)

After a fresh user-approved **full-display** screenshot is inspected, RelayOS
can visually select the item instead of merely pointing at it:

- `highlight_screen_region(shape, x, y, width, height, ...)`: `rect`,
  `rounded_rect` or `ellipse`, all bounds normalized 0–1 from the top-left.
- `highlight_screen_path(points, shape="polygon"|"path", ...)`: 2–96
  normalized `[x,y]` vertices. A polygon is closed (3+ points); freeform
  path may be open or closed, supporting nonuniform outlines.
- `clear_screen_highlight()`: dismiss both the overlay and any directed cursor.

Optional parameters: `display="main"`, `hold_seconds=20` (1–60),
`proximity_radius=48` (0–200 macOS screen points),
`show_cursor=true`, `fill_opacity=0.12` (0–0.25),
`stroke_width=2.5` (1–6). Rectangles support
`corner_radius=10` (0–40 points). An open path is never filled.

The native UI displays a separate click-through, transparent overlay above the
selected display. The accent-color outline animates from the top-left edge
(rectangles) or first supplied vertex (paths), then a translucent fill fades in.
The existing virtual triangle optionally moves toward the item, rotates and
holds near it. A real mouse entering the shape or a configurable surrounding
margin **from outside** dismisses the outline and returns the triangle to its
normal follow mode. Timeouts, explicit clear, disabled guidance and Emergency
Stop also dismiss. Only one target is active. No OS cursor manipulation,
injected clicks, persistent image data or recording are involved.

The running app must be rebuilt before this functionality is available;
reconnecting the ChatGPT RelayOS connector may also be necessary to discover
the new MCP tools. macOS-native tests and live visual behavior remain to be
verified on the signed bundle.

## Native automatic walkthroughs (read-only observation)

RelayOS supports a bounded `system_settings_general` recipe for hands-free
step verification. Invoke `start_guided_walkthrough(flow="system_settings_general",
duration_seconds=600)` when the user asks to begin. The signed Mac app polls
the token-authenticated `GET /control/walkthrough` endpoint every 1.2 seconds.
It checks that System Settings (`com.apple.systempreferences`) is foreground,
then examines macOS Accessibility metadata for the *General* item only.
An exact, on-screen element rectangle may be used to highlight the control.
Only verified selected state completes the final step; switching apps clears
stale highlights and shows a return instruction.

The assistant does not stay awake, stream screenshots, or poll itself: a
local, temporary native observer handles progress. No mouse or keyboard
input is injected and no screenshot is captured. The workflow expires after
up to 15 minutes, and after 45 seconds on a step it shows an attention
reminder but **never skips an unverified step**. A user can pause/resume/stop
from the RelayOS menu-bar control center. Emergency Stop revokes immediately.
`guided_walkthrough_status` reports current progress and
`stop_guided_walkthrough` ends the session.

If macOS Accessibility permission for RelayOS is missing or the control
cannot be located, no completion is inferred and no fake highlight is drawn.
Open **System Settings → Privacy & Security → Accessibility** and enable the
installed signed RelayOS app to allow the verified General selection.

The MVP is an allowlisted **System Settings → General** walkthrough, not a
general-purpose visual agent or an arbitrary website automation engine.
The flow is intentionally explicit and time-limited.

## ChatGPT responses beside the cursor

A short plain-text RelayOS guidance tip can be shown without an additional
screen capture or screenshot approval:

- `show_cursor_tip(message="Click your profile icon here", hold_seconds=20)`
  displays an optional typewritten bubble next to the virtual cursor while
  the cursor follows the real mouse (without moving or clicking it).
- `point_screen_target(..., tip="Choose this tab")`,
  `highlight_screen_region(..., tip="Open Settings here")`, and
  `highlight_screen_path(..., tip="This is the control")` attach a bubble
  to the existing target; the message closes with the highlighted target when
  mouse proximity is reached or the target times out.
- `clear_cursor_tip()` removes only the text, preserving the current
  highlight. `clear_screen_pointer()` and `clear_screen_highlight()`
  remove target and bubble.

The small transparent, click-through SwiftUI bubble follows the current
*virtual* triangle position, keeps within the display bounds, and types
approximately 32 visible characters per second with a blinking caret. Its
panel displays RelayOS's current accent color. Text is bounded to 240
characters (1000 UTF-8 bytes); duration is 1–60 seconds. Exactly one
message can be shown at once; a new tip replaces the old tip. It is not a
general OS input or notification channel. Emergency Stop and disabled Screen
Guidance revoke the tip, and no message transcript is stored.

ChatGPT's normal chat output is **not automatically mirrored** to RelayOS:
the assistant calls one of the MCP tip/guidance tools to display the chosen
short text on the Mac.

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
