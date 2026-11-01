<!-- Path: docs/MENU_BAR_NOTCH_UI.md -->
# RelayOS — macOS menu bar and notch companion

The app remains a settings-first native macOS application. This UI sprint
improves three surfaces without changing the MCP runtime:

1. The **RelayOS Controls** menu under the macOS app menu.
2. The compact **menu-bar control center** opened by the status icon.
3. An **optional top-center companion panel** opened from the menu bar, the
   main Settings toolbar, or the keyboard.

## Current notch navigation — 2026-11-01

The expanded notch contains exactly **three permanent tabs**: **Terminal**, **Approvals**, and **Settings**. All three labels are visible on standard notched MacBook displays, whether or not there are pending approvals. The expanded body width is now at least 820pt plus the curved notch edges, keeping the camera exclusion black and unoccupied. Smaller displays use icon-only tabs with accessible names where full labels cannot fit. **Terminal** opens current job activity and history, **Approvals** shows the live approval queue/actions, and **Settings** contains MCP health, endpoint copying, and the main Settings link. The Music tab has been removed from the notch, but its native adapter remains available in the source for a possible later integration. The notch no longer polls music services or widens on music playback.

Saved tab preferences are migrated automatically: old Activity or Music selections open Terminal; System opens Settings. Collapsed and hover geometry remains unchanged. Manual inspection on the 14-inch screen is still recommended before deployment.

## Open and use

- Click the RelayOS status icon to inspect local/public MCP health, pending
  approvals, connected clients and service notices.
- Click **Show notch** to open a compact, black build-status extension. On a MacBook with a camera notch, the left and right ears align with the menu-bar strip, leaving the physical notch zone transparent. The lower tray begins beneath the menu-bar strip. On other displays the entire companion appears just below the menu bar.
- In the main Settings window, click **Notch panel** in the new upper-right
  controls to show or hide it.
- Use **RelayOS Controls → Toggle Notch Panel**, shortcut **⌘⌥N**.
- Use **RelayOS Controls → Open Control Center**, shortcut **⌘⌥O**.
- Left ear: actual RelayOS application icon and product name. Right ear: current running executable/build name and live elapsed time. Below: a compact active-job tray showing the project, job count and a link to Terminal Jobs. The tray and right ear open the live terminal console; the × control and Escape dismiss it.
- The panel is opt-in and uses native AppKit `NSPanel`. Position and the empty center gap come from `NSScreen.auxiliaryTopLeftArea`, `auxiliaryTopRightArea`, and visible/display frames—not hard-coded 14-inch physical dimensions. It repositions on display changes.

## Behavior and privacy

- In the ordinary app, all Python-backed services and approvals stay available.
  The UI reads the existing `BridgeModel` rather than creating new servers.
- Xcode development mode must not restart or claim the installed services.
- Swift-only Debug mode continues to use its isolated listener on port 18765;
  the menu-bar panel is interactive and routes **Review** to the native inbox.
- The menu-bar badge counts the relevant inbox, including native development
  requests. The native count is updated while the development listener runs.
- **Emergency stop** and **Restart services** require explicit confirmation.
  Both are unavailable when the app is observing the installed agent from Xcode.
- The notch companion never captures the screen or sends keystrokes and has no
  hidden global input-monitoring behavior.
- The notch extension deliberately uses pure black chrome matching the physical camera housing, independently of the Settings theme. The menu-bar control center retains its system theme and accent.

## In-file previews

- `Views/QuickPanel/QuickPanel.swift` provides connected and disconnected
  `#Preview` samples.
- `Views/QuickPanel/NotchPanel.swift` provides previews for an active build and a screen without a camera housing, directly beside the view implementation.
- The main Settings window's native preview now also contains the top controls.

## Manual visual QA (still required)

- Verify menu item actions after closing and reopening the main window.
- Check dark/light themes, type size, emergency-stop confirmation and tunnel
  failure descriptions.
- Confirm that nothing is drawn across the actual camera/notch exclusion on a 14-inch or 16-inch MacBook. The side ears should fit in the menu-bar strip, with the lower tray below it. Verify external monitors with negative coordinates, scaling changes, Spaces and full-screen apps.
- Check keyboard-only access, VoiceOver labels, and behavior when a native
  approval request arrives.
- Compare both standard Python-backed and Swift-only Debug paths.

Automated layout tests cover screen-placement calculations, but do not replace
manual macOS screenshots and accessibility checks. No production deployment
is included in this UI sprint.

## Compact build-status update — 2026-11-01

- The previous large, material-background control panel is replaced by a 568pt nominal-width, ~112pt-high hardware-aware extension.
- Shows the app logo at left and the currently running command name/elapsed time at right, with no content drawn in the actual camera exclusion.
- Shows current running/queued terminal jobs in the black lower tray; tapping opens the relevant job and its live output in the main RelayOS window.
- Empty state is explicit (`No running builds`). A completed-job progress percentage is never fabricated for this glanceable UI.
- Geometry is tested for a 14-inch-sized housing, a wider housing, an external monitor, and narrow layouts.
- The panel uses the existing `BridgeModel.commandJobs` publisher and the existing Python-backed hybrid job monitoring. No backend or production bundle changes are required for this UI change.

## Unified notch hover interaction — 2026-11-01

The notch is now **one continuous, black surface**, including an intentionally
empty black physical-camera region in the top center. There is no transparent
split between the logo and active build, and the lower tray is **not** left open
when idle.

- **Collapsed**: ~394pt wide, only the menu-bar-height black band; RelayOS icon
  on the left, running command and elapsed time on the right. No text or other
  controls are placed inside the camera housing.
- **Hover**: the band widens to ~474pt and a subtle 28pt status hint appears,
  accompanied by a trackpad haptic when macOS hardware/settings support it.
- **Click**: expands to ~568pt wide with the 94pt build-status tray; opens the
  full Terminal Jobs console from the tray. Expansion also requests a haptic.
- **Mouse leave**: collapses back to the compact band after a brief guard against
  spurious mouse-leave events caused by resizing. It does **not** terminate the
  companion itself; use the Settings/menu-bar toggle or the explicit close
  button when expanded to hide the companion entirely.
- **Escape**: collapses to the compact band.

Geometry continues to use the live NSScreen auxiliary top regions on Macs with
a notch. On external monitors, the black panel remains below the menu bar.
The view contains local #Preview examples for collapsed, hover, and expanded
states, plus six geometry tests. Manually inspect the actual macOS menu-bar
interaction on a 14-inch MacBook before deploying a signed bundle.

## Native music playback controls — 2026-11-01

RelayOS's existing **Music** notch tab now presents only playback metadata and
transport controls. It shows track title, artist, album, player name, Spotify
artwork when available, current position, track duration, an interactive
progress scrubber, and **Previous / Play-Pause / Next**. Progress advances from
the most recent player-reported position while playing, stays fixed while
paused, and clamps to track duration. If timing is unavailable, the UI shows an
indeterminate/disabled progress surface rather than fabricating timing.

The source is native macOS Automation (NSAppleScript), with queries and actions
performed away from the UI thread. RelayOS polls already-running Apple Music
and Spotify every two seconds and prefers the actively playing app. Playback
controls target only the discovered player; they never implicitly open a music
app. macOS may prompt for **Automation** permission the first time RelayOS
accesses a supported player. If permission is denied or no supported player is
running, the panel displays a straightforward empty state with disabled
controls.

**Important platform limitation:** Apple's public Now Playing / MediaPlayer
APIs publish a player's own controls and metadata; they do not offer a
supported way to inspect arbitrary other apps' playback. Generic web browsers,
YouTube tabs, and other players are not represented by this implementation.
Accessing private MediaRemote APIs or bypassing macOS protections is not part
of this update. Other players require explicit integration and compatibility
review.

### Local acceptance checks

- Play a song in Apple Music, then Spotify: inspect title, artist, album,
  playback icon, duration, current time and progress movement.
- Pause/resume, skip forward/back, and scrub the progress bar: ensure the
  correct running player responds and the UI refreshes.
- Deny Automation access: no player launches and no controls are enabled.
- Pause a track: elapsed time should remain fixed, and metadata should stay
  visible in the compact notch.
- Run a terminal build while a track plays: approvals and build activity retain
  their priority in the compact status; Music remains accessible in the tray.

Automated tests cover metadata parsing, unit conversion, missing timing,
position interpolation, pause behavior and duration clamping. Real-player
Automation consent and transport behavior require testing in a signed local
build, not just Xcode compilation.

## System playback and audio routing refinement — 2026-11-01

The macOS Control Center obtains **system-wide** Now Playing metadata from an
Apple-managed service. macOS 15.4+ restricts third-party processes from
accessing the private MediaRemote client; the public Now Playing APIs publish
**your own app's playback**, not another app's metadata. RelayOS does not inject
code into macOS daemons, borrow privileged Apple process entitlements, disable
SIP, or claim universal Control Center metadata access.

Music/Spotify are read through their supported AppleScript dictionaries.
The adapters no longer compile Spotify-specific artwork terminology into a
Music script; they report Automation failures and distinguish stopped players
from an unsupported browser playback source. Grant the signed RelayOS app
Automation permissions in **System Settings → Privacy & Security → Automation**
when prompted. Permissions are specific to the signing identity and app.

The music tray additionally has:

- **Previous, play/pause, next:** target the discovered supported player; when
  no supported player is detected, use user-approved macOS Accessibility
  **media-key events** targeting the current system media session. Enable this
  only by clicking **Enable media keys** in the notch and granting RelayOS
  Accessibility permissions in System Settings. A media-key event may work
  for browser playback even when title/artist cannot be read.
- **AirPlay icon:** an Apple `AVRoutePickerView` system-provided destination
  picker, meant for app-associated media routes. It is not a guaranteed
  global output switch for other applications.
- **System output:** opens the macOS Sound Settings pane so the person can
  select the Mac's actual output device, including available AirPlay targets.
- **Metadata diagnostics:** clear reasons when no supported player is
  running, AppleScript reads fail, or macOS Automation access is denied.

### Remaining compatibility gaps

Real browser/system-wide media metadata, album art and scrub position are
**not available to ordinary third-party apps through an Apple-supported
system-wide reader**. RelayOS shows an honest empty state rather than fabricated
Control Center data. Capturing Control Center's visible UI with Accessibility
would be unreliable and require explicit consent and interaction; it is not
silently scraped. Playback and AirPlay need real signed-app/manual QA with
system and supported third-party apps.
