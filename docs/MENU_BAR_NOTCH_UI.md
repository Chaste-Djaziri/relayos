<!-- Path: docs/MENU_BAR_NOTCH_UI.md -->
# RelayOS — macOS menu bar and notch companion

The app remains a settings-first native macOS application. This UI sprint
improves three surfaces without changing the MCP runtime:

1. The **RelayOS Controls** menu under the macOS app menu.
2. The compact **menu-bar control center** opened by the status icon.
3. An **optional top-center companion panel** opened from the menu bar, the
   main Settings toolbar, or the keyboard.

## Open and use

- Click the RelayOS status icon to inspect local/public MCP health, pending
  approvals, connected clients and service notices.
- Click **Show notch** to show the floating quick panel below the macOS menu bar.
  It is not drawn over the hardware camera notch or native menu items.
- In the main Settings window, click **Notch panel** in the new upper-right
  controls to show or hide it.
- Use **RelayOS Controls → Toggle Notch Panel**, shortcut **⌘⌥N**.
- Use **RelayOS Controls → Open Control Center**, shortcut **⌘⌥O**.
- The floating panel offers **Open RelayOS**, **Review** and **Copy MCP**.
  **Close** dismisses it; no timer or background accessibility service is used.
- The panel is opt-in, uses native AppKit `NSPanel`, and responds to display
  parameter changes. On a Mac without a notch, it still appears centered below
  the menu bar.

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
- App theme and accent choices apply to the new UI.

## In-file previews

- `Views/QuickPanel/QuickPanel.swift` provides connected and disconnected
  `#Preview` samples.
- `Views/QuickPanel/NotchPanel.swift` provides dark and light previews.
- The main Settings window's native preview now also contains the top controls.

## Manual visual QA (still required)

- Verify menu item actions after closing and reopening the main window.
- Check dark/light themes, type size, emergency-stop confirmation and tunnel
  failure descriptions.
- Confirm that the panel stays below the macOS menu bar on notched MacBook
  displays, external monitors with negative coordinates, and displays with
  changed scaling or Spaces.
- Check keyboard-only access, VoiceOver labels, and behavior when a native
  approval request arrives.
- Compare both standard Python-backed and Swift-only Debug paths.

Automated layout tests cover screen-placement calculations, but do not replace
manual macOS screenshots and accessibility checks. No production deployment
is included in this UI sprint.
