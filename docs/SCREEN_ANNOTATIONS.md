# RelayOS direct on-screen drawing (macOS)

## What changed

RelayOS can now paint plain text labels, colored arrows, rectangles, circles,
polyline scribbles, and code snippets DIRECTLY above the user's current
application or image, instead of opening its floating Teaching Notepad.
Annotations are click-through and do not alter the underlying content.

This mode is for requests such as **"label the parts of the car on my
screen"**, "draw on the diagram", "circle the error in VS Code", "show me the
settings control", and "write on the slide itself". The notepad remains
available through explicit `open_guidance_notepad` requests.

## MCP contract

1. Obtain a current **user-approved full-display screenshot** through
   `request_screen_capture` and `capture_approved_screen`. Full-display
   dimensions and coordinates have the screenshot's top-left as (0,0).
   Never invent visual positions from an app-window crop.
2. Call `draw_screen_annotations(elements, display="main",
   duration_seconds=240, replace=false)` with up to 40 items. Elements
   are positioned in normalized display coordinates (0..1) and can be:
   `label`, `text`, `code`, `rect`, `ellipse`, `arrow`, `line`,
   `path` or `scribble`. Text is plain UTF-8 only; no HTML or scripts.
   Arrows are line vectors from (x,y) to (x+w,y+h), which permits negative
   deltas for pointing upward or leftward.
3. Each item returns a unique annotation ID. For changes, use
   `erase_screen_annotations(ids=[...])`; to clear everything on the
   active display, call `erase_screen_annotations(display="main")`;
   `clear_all_screen_annotations` erases every display. Alternatively,
   a new `draw_screen_annotations(... replace=true)` replaces ONLY
   the current display's visual annotations. The public
   `screen_annotation_status` reports currently alive IDs.
4. Drawing expires automatically (default 240 seconds, max 900 seconds).
   Expired marks are never persisted or restored after a helper restart.
   The user can also select **Clear on-screen drawings** in RelayOS's
   menu bar panel, or the app's **RelayOS Controls** menu.
5. Add `only_when_app: "com.microsoft.VSCode"` to an element to
   hide it when that app is no longer foreground; the native companion
   checks the active bundle locally without uploading it.

For example, to label a front wheel at x=.42/y=.62 of an approved car
screenshot:

```json
[
  {"kind":"label","x":0.14,"y":0.24,"w":0.22,
   "text":"Front wheel","color":"yellow","font_size":20},
  {"kind":"arrow","x":0.31,"y":0.30,"w":0.13,"h":0.28,
   "color":"yellow","stroke_width":4},
  {"kind":"ellipse","x":0.37,"y":0.54,"w":0.13,"h":0.18,
   "color":"red","stroke_width":3},
  {"kind":"scribble","x":0,"y":0,
   "points":[[0.6,0.3],[0.62,0.32],[0.63,0.35],[0.67,0.37]],
   "color":"green"}
]
```

These coordinates are purely illustrative. Real labels must be grounded in
the screenshot the user has approved.

## How the native renderer works

`RelayOSOnscreenAnnotations` polls the control-token authenticated local
`/control/screen-annotations` endpoint. Transparent per-display
`NSPanel` windows draw paths directly in SwiftUI, on all Spaces and
full-screen apps where permitted by macOS. They cannot accept mouse or
keyboard events and cannot alter the system pointer. Their sharing type is
`none` to keep the overlays out of screenshots.

The UI is loaded independently of the notepad. Existing cursor and
single-target highlight overlays can operate alongside it.

## Lessons and remaining limitations

The existing locally approved guided-lesson engine now renders a compact
step label directly on screen and advances to the next step when its
declared action metadata is observed. It removes ONLY its previous label.
It does not automatically open or clear the Teaching Notepad.
When the step requires human evaluation, use **Done** in the menu-bar
**Live guidance** controls.

Positions are attached to the DISPLAY, not the contents of moving/scrolling
applications. When a user scrolls, zooms, moves a window or changes an image,
a previous annotation may be out of alignment: request a fresh approved
screenshot, erase obsolete IDs and redraw. The app does not yet perform
computer vision/tracking or continuously call the ChatGPT model in the
background. The native action observer remains opt-in and time-limited.
Screen Recording and local approval permissions are unaffected.

## Validation

- Python screen-annotation and guided lesson suites.
- Swift overlay path geometry, decoded annotations, display/application
  visibility rules and entire native test suite.
- Signed production hybrid build and isolated OAuth/MCP restart smoke test
  before a rollback-protected deployment.
