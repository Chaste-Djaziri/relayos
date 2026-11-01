// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Views/QuickPanel/NotchPanel.swift
import AppKit
import AVKit
import ApplicationServices
import Combine
import SwiftUI

enum NotchPanelPhase: String, CaseIterable {
    case collapsed
    case hovered
    case expanded

    var topCornerRadius: CGFloat {
        switch self {
        case .collapsed: 10
        case .hovered: 12
        case .expanded: 14
        }
    }

    var bottomCornerRadius: CGFloat {
        switch self {
        case .collapsed: 13
        case .hovered: 15
        case .expanded: 20
        }
    }

    var trayHeight: CGFloat {
        switch self {
        case .collapsed: 0
        case .hovered: 6
        case .expanded: 174
        }
    }
}

/// Extensible sub-pages hosted inside the expanded notch tray.
enum NotchSubpage: String, CaseIterable, Identifiable {
    case activity
    case approvals
    case music
    case services

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activity: "Activity"
        case .approvals: "Approve"
        case .music: "Music"
        case .services: "System"
        }
    }

    var icon: String {
        switch self {
        case .activity: "terminal.fill"
        case .approvals: "checkmark.shield.fill"
        case .music: "music.note"
        case .services: "slider.horizontal.3"
        }
    }
}

/// Hardware-style notch silhouette whose top-left and top-right corners flare
/// outwards flush with the very top edge (`y = 0`) and whose bottom corners
/// curve smoothly inwards with continuous curvature.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let tr = min(max(0, topCornerRadius), rect.width / 4, rect.height / 2)
        let bodyWidth = max(0, rect.width - (tr * 2))
        let br = min(max(0, bottomCornerRadius), bodyWidth / 2, max(0, rect.height - tr))

        let leftWallX = rect.minX + tr
        let rightWallX = rect.maxX - tr

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Top-left continuous outward fillet (tangent to top display edge at minX, 0)
        if tr > 0 {
            path.addCurve(
                to: CGPoint(x: leftWallX, y: rect.minY + tr),
                control1: CGPoint(x: rect.minX + tr * 0.55, y: rect.minY),
                control2: CGPoint(x: leftWallX, y: rect.minY + tr * 0.45)
            )
        }

        // Left vertical edge down to bottom fillet
        path.addLine(to: CGPoint(x: leftWallX, y: rect.maxY - br))

        // Bottom-left continuous inward fillet
        if br > 0 {
            path.addCurve(
                to: CGPoint(x: leftWallX + br, y: rect.maxY),
                control1: CGPoint(x: leftWallX, y: rect.maxY - br * 0.45),
                control2: CGPoint(x: leftWallX + br * 0.45, y: rect.maxY)
            )
        }

        // Bottom horizontal edge
        path.addLine(to: CGPoint(x: rightWallX - br, y: rect.maxY))

        // Bottom-right continuous inward fillet
        if br > 0 {
            path.addCurve(
                to: CGPoint(x: rightWallX, y: rect.maxY - br),
                control1: CGPoint(x: rightWallX - br * 0.45, y: rect.maxY),
                control2: CGPoint(x: rightWallX, y: rect.maxY - br * 0.45)
            )
        }

        // Right vertical edge up to top fillet
        path.addLine(to: CGPoint(x: rightWallX, y: rect.minY + tr))

        // Top-right continuous outward fillet (tangent to top display edge at maxX, 0)
        if tr > 0 {
            path.addCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY),
                control1: CGPoint(x: rightWallX, y: rect.minY + tr * 0.45),
                control2: CGPoint(x: rect.maxX - tr * 0.55, y: rect.minY)
            )
        }

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// The physical camera region is filled with black, but deliberately has no
/// text, icons, or interactive controls. The entire shape is one black surface.
enum NotchPanelPlacement {
    struct Layout: Equatable {
        let frame: CGRect
        let topBandHeight: CGFloat
        let topCornerRadius: CGFloat
        let bottomCornerRadius: CGFloat
        let centerGap: CGFloat
        let leftWidth: CGFloat
        let rightWidth: CGFloat
        let hasHardwareNotch: Bool
        let hasLiveActivity: Bool
        let phase: NotchPanelPhase

        var bodyWidth: CGFloat {
            leftWidth + centerGap + rightWidth
        }
    }

    static let preferredWidth: CGFloat = 540
    static let trayHeight: CGFloat = NotchPanelPhase.expanded.trayHeight

    static func layout(
        displayFrame: CGRect,
        visibleFrame: CGRect,
        hardwareNotchWidth: CGFloat? = nil,
        phase: NotchPanelPhase = .collapsed,
        hasLiveActivity: Bool = false
    ) -> Layout {
        let menuBand = max(0, displayFrame.maxY - visibleFrame.maxY)
        let hasNotch = (hardwareNotchWidth ?? 0) > 60 && menuBand > 15
        let topHeight = menuBand > 15 ? min(max(30, menuBand), 42) : 34
        let topRadius = phase.topCornerRadius
        let bottomRadius = phase.bottomCornerRadius
        let realNotchWidth = max(hardwareNotchWidth ?? 185, 160)
        let maxBodyWidth = max(80, visibleFrame.width - 24 - (topRadius * 2))

        let centerGap: CGFloat
        let leftWidth: CGFloat
        let rightWidth: CGFloat

        switch phase {
        case .collapsed:
            if hasLiveActivity {
                let minGap = realNotchWidth + 12
                let requestedBody = max(396, minGap + 196)
                let bodyWidth = min(requestedBody, maxBodyWidth)
                let gap = min(minGap, max(1, bodyWidth - 130))
                let sides = max(0, bodyWidth - gap)
                let left = (sides * 0.46).rounded(.down)
                centerGap = gap
                leftWidth = left
                rightWidth = sides - left
            } else {
                // Exact hardware notch footprint when idle: no side wings.
                centerGap = min(realNotchWidth, maxBodyWidth)
                leftWidth = 0
                rightWidth = 0
            }

        case .hovered:
            if hasLiveActivity {
                let minGap = realNotchWidth + 12
                let requestedBody = max(422, minGap + 220)
                let bodyWidth = min(requestedBody, maxBodyWidth)
                let gap = min(minGap, max(1, bodyWidth - 140))
                let sides = max(0, bodyWidth - gap)
                let left = (sides * 0.46).rounded(.down)
                centerGap = gap
                leftWidth = left
                rightWidth = sides - left
            } else {
                // Small hover expansion with nothing drawn on it when idle.
                centerGap = min(realNotchWidth + 28, maxBodyWidth)
                leftWidth = 0
                rightWidth = 0
            }

        case .expanded:
            let minGap = realNotchWidth + 12
            let requestedBody = max(preferredWidth, minGap + 310)
            let bodyWidth = min(requestedBody, maxBodyWidth)
            let gap = min(minGap, max(1, bodyWidth - 140))
            let sides = max(0, bodyWidth - gap)
            let left = (sides * 0.44).rounded(.down)
            centerGap = gap
            leftWidth = left
            rightWidth = sides - left
        }

        let totalWidth = leftWidth + centerGap + rightWidth + (topRadius * 2)
        let height = topHeight + phase.trayHeight
        // Always flush with the very top pixel of the display.
        let topEdge = displayFrame.maxY

        return Layout(
            frame: CGRect(
                x: visibleFrame.midX - totalWidth / 2,
                y: topEdge - height,
                width: totalWidth,
                height: height
            ),
            topBandHeight: topHeight,
            topCornerRadius: topRadius,
            bottomCornerRadius: bottomRadius,
            centerGap: centerGap,
            leftWidth: leftWidth,
            rightWidth: rightWidth,
            hasHardwareNotch: hasNotch,
            hasLiveActivity: hasLiveActivity,
            phase: phase
        )
    }

    static func layout(
        for screen: NSScreen,
        phase: NotchPanelPhase = .collapsed,
        hasLiveActivity: Bool = false
    ) -> Layout {
        let gap: CGFloat?
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           left.width > 0, right.width > 0, right.minX > left.maxX {
            gap = right.minX - left.maxX
        } else {
            gap = nil
        }
        return layout(
            displayFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            hardwareNotchWidth: gap,
            phase: phase,
            hasLiveActivity: hasLiveActivity
        )
    }
}

/// Non-activating top-edge panel that is excluded from screenshots/recordings
/// and never constrained below the menu bar by AppKit.
final class RelayOSNotchWindow: NSPanel {
    private weak var trackedContentView: NSView?
    private var pointerTrackingArea: NSTrackingArea?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )
        configureNotchWindow()
    }

    private func configureNotchWindow() {
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [
            // A physical notch belongs to the currently visible desktop, not
            // to a copy of the panel left behind on every Space. AppKit moves
            // this panel as Spaces change instead of duplicating it.
            .moveToActiveSpace,
            .ignoresCycle
        ]
        // Make the notch completely invisible in screenshots and screen recordings.
        sharingType = .none
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        // SwiftUI's onHover only receives events after its shaped content has
        // won hit testing. The window-level tracker keeps hover expansion
        // reliable for an external mouse and for the black camera silhouette.
        acceptsMouseMovedEvents = true
    }

    func installPointerTracking() {
        guard let contentView else { return }
        if let pointerTrackingArea, trackedContentView === contentView {
            contentView.removeTrackingArea(pointerTrackingArea)
        }
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        contentView.addTrackingArea(tracking)
        trackedContentView = contentView
        pointerTrackingArea = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        NotchPanelCoordinator.shared.hover(true)
    }

    override func mouseExited(with event: NSEvent) {
        NotchPanelCoordinator.shared.hover(false)
    }

    override func sendEvent(_ event: NSEvent) {
        // A non-activating panel may receive its first click while a different
        // app owns key focus. Expand before passing that event to SwiftUI so a
        // click on the physical silhouette is never discarded.
        if event.type == .leftMouseDown,
           NotchPanelCoordinator.shared.phase != .expanded {
            NotchPanelCoordinator.shared.expand()
        }
        super.sendEvent(event)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Allow the notch window to sit flush with the very top edge of the screen
        // without AppKit pushing it below the menu bar.
        frameRect
    }

    override func cancelOperation(_ sender: Any?) {
        NotchPanelCoordinator.shared.collapse()
    }
}

/// Timeline calculations are separated from the UI so missing/malformed
/// metadata never produces a fake progress bar.
enum NotchPlaybackTimeline {
    static func position(elapsed: TimeInterval?, duration: TimeInterval?,
                         isPlaying: Bool, observedAt: Date, now: Date) -> TimeInterval? {
        guard let elapsed, elapsed.isFinite, elapsed >= 0 else { return nil }
        let advanced = elapsed + (isPlaying ? max(0, now.timeIntervalSince(observedAt)) : 0)
        if let duration, duration.isFinite, duration > 0 {
            return min(max(0, advanced), duration)
        }
        return max(0, advanced)
    }

    static func clock(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "–:––" }
        let total = Int(seconds)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Sends the same media-key events as a hardware keyboard, only after the
/// person explicitly grants RelayOS Accessibility access. No private
/// MediaRemote entitlements or system process injection are used.
enum RelayOSMediaKeys {
    enum Key: Int { case toggle = 16, next = 17, previous = 18 }

    static var isAuthorized: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestPermission() -> Bool {
        AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary)
    }

    @discardableResult
    static func send(_ key: Key) -> Bool {
        guard isAuthorized else { return false }
        for down in [true, false] {
            let data = (key.rawValue << 16) | (down ? 0xA00 : 0xB00)
            guard let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil,
                subtype: 8, data1: data, data2: -1
            )?.cgEvent else { return false }
            event.post(tap: .cghidEventTap)
        }
        return true
    }
}

/// AirPlay routes shown by AVKit are associated with the local app's media
/// session. For routing *other* apps, use macOS Sound output settings below.
struct RelayOSAirPlayPicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        AVRoutePickerView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
    }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

/// A system-wide "currently playing" reader is not available through Apple's
/// public media APIs. This native adapter supports already-running Music and
/// Spotify via their AppleScript dictionaries and macOS Automation consent.
/// It never launches an application implicitly, reads the MCP backend, or
/// claims to control unrelated browsers/players.
@MainActor
final class NotchMediaController: ObservableObject {
    static let shared = NotchMediaController()

    @Published private(set) var isPlaying = false
    @Published private(set) var trackTitle = ""
    @Published private(set) var artistName = ""
    @Published private(set) var albumName = ""
    @Published private(set) var playerName = "Music"
    @Published private(set) var playerBundleIdentifier = "com.apple.Music"
    @Published private(set) var hasRunningPlayer = false
    @Published private(set) var duration: TimeInterval?
    @Published private(set) var elapsed: TimeInterval?
    @Published private(set) var observedAt = Date()
    @Published private(set) var artworkURL: URL?
    @Published private(set) var commandInFlight = false
    @Published private(set) var sourceMessage = "Checking playback sources…"
    @Published private(set) var automationPermissionNeeded = false

    private var pollTask: Task<Void, Never>?

    struct Snapshot: Sendable, Equatable {
        let isPlaying: Bool
        let trackTitle: String
        let artistName: String
        let albumName: String
        let playerName: String
        let playerBundleIdentifier: String
        let duration: TimeInterval?
        let elapsed: TimeInterval?
        let artworkURL: String?
    }

    /// AppleScript record separator avoids corrupting titles containing "||".
    nonisolated static func parseSnapshot(_ raw: String, player: String,
                                          bundle: String) -> Snapshot? {
        let parts = raw.components(separatedBy: "\u{001E}")
        guard parts.count >= 6,
              ["playing", "paused"].contains(parts[0]),
              !parts[1].isEmpty else { return nil }
        let position = Double(parts[4])
        let rawDuration = Double(parts[5])
        let duration = rawDuration.map { bundle == "com.spotify.client" ? $0 / 1000 : $0 }
        let validDuration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let validPosition = position.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let artwork = parts.count > 6 && parts[6].hasPrefix("https://") ? parts[6] : nil
        return Snapshot(isPlaying: parts[0] == "playing", trackTitle: parts[1],
                        artistName: parts[2], albumName: parts[3],
                        playerName: player, playerBundleIdentifier: bundle,
                        duration: validDuration, elapsed: validPosition,
                        artworkURL: artwork)
    }

    func position(at date: Date = Date()) -> TimeInterval? {
        NotchPlaybackTimeline.position(
            elapsed: elapsed, duration: duration,
            isPlaying: isPlaying, observedAt: observedAt, now: date)
    }

    func startMonitoring() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        let runningBundles = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let lookup = await Task.detached(priority: .utility) {
            Self.queryRunningPlayers(runningBundles: runningBundles)
        }.value
        let snapshot = lookup.snapshot
        guard !Task.isCancelled else { return }
        sourceMessage = lookup.message
        automationPermissionNeeded = lookup.automationDenied
        if let snapshot {
            let changedTrack = trackTitle != snapshot.trackTitle ||
                artistName != snapshot.artistName ||
                playerBundleIdentifier != snapshot.playerBundleIdentifier
            hasRunningPlayer = true
            isPlaying = snapshot.isPlaying
            trackTitle = snapshot.trackTitle
            artistName = snapshot.artistName
            albumName = snapshot.albumName
            playerName = snapshot.playerName
            playerBundleIdentifier = snapshot.playerBundleIdentifier
            duration = snapshot.duration
            elapsed = snapshot.elapsed
            observedAt = Date()
            if changedTrack || artworkURL?.absoluteString != snapshot.artworkURL {
                artworkURL = snapshot.artworkURL.flatMap(URL.init(string:))
            }
        } else {
            hasRunningPlayer = false
            isPlaying = false
            trackTitle = ""
            artistName = ""
            albumName = ""
            duration = nil
            elapsed = nil
            artworkURL = nil
        }
    }

    func togglePlayPause() { send(.toggle) }
    func requestMediaKeyAccess() {
        _ = RelayOSMediaKeys.requestPermission()
    }
    func nextTrack() { send(.next) }
    func previousTrack() { send(.previous) }

    func seek(to time: TimeInterval) {
        guard let target = runningPlayerName(),
              let duration, duration.isFinite, duration > 0,
              time.isFinite, time >= 0, !commandInFlight else { return }
        let position = Int(min(duration, time))
        commandInFlight = true
        Task { [weak self] in
            _ = await Task.detached(priority: .userInitiated) {
                Self.runAppleScript("tell application \"\(target)\" to set player position to \(position)")
            }.value
            guard let self else { return }
            self.commandInFlight = false
            await self.refresh()
        }
    }

    private enum PlaybackAction {
        case toggle, next, previous
        var mediaKey: RelayOSMediaKeys.Key {
            switch self {
            case .toggle: .toggle
            case .next: .next
            case .previous: .previous
            }
        }
        var script: String {
            switch self {
            case .toggle: "playpause"
            case .next: "next track"
            case .previous: "previous track"
            }
        }
    }

    private func send(_ action: PlaybackAction) {
        guard !commandInFlight else { return }
        guard let target = runningPlayerName(), hasRunningPlayer else {
            if !RelayOSMediaKeys.send(action.mediaKey) {
                sourceMessage = "Enable Accessibility for RelayOS to use system-wide media keys."
            }
            return
        }
        commandInFlight = true
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.runAppleScript("tell application \"\(target)\" to \(action.script)")
            }.value
            guard let self else { return }
            self.commandInFlight = false
            if result.message != nil, !RelayOSMediaKeys.send(action.mediaKey) {
                self.sourceMessage = "Playback command blocked. Check Automation, or enable Accessibility for system media keys."
            }
            await self.refresh()
        }
    }

    #if DEBUG
    func applyPreviewState(
        isPlaying: Bool,
        trackTitle: String = "",
        artistName: String = "",
        playerName: String = "Music",
        duration: TimeInterval? = 234,
        elapsed: TimeInterval? = 83
    ) {
        self.isPlaying = isPlaying
        self.hasRunningPlayer = !trackTitle.isEmpty
        self.trackTitle = trackTitle
        self.artistName = artistName
        self.playerName = playerName
        self.duration = duration
        self.elapsed = elapsed
        self.observedAt = Date()
    }
    #endif

    private func runningPlayerName() -> String? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        guard hasRunningPlayer else { return nil }
        if running.contains(playerBundleIdentifier) {
            return playerBundleIdentifier == "com.spotify.client" ? "Spotify" : "Music"
        }
        return nil
    }

    struct PlayerLookup: Sendable {
        let snapshot: Snapshot?
        let message: String
        let automationDenied: Bool
    }

    nonisolated private static func queryRunningPlayers(
        runningBundles: Set<String>
    ) -> PlayerLookup {
        let candidates: [(bundle: String, name: String)] = [
            ("com.apple.Music", "Music"),
            ("com.spotify.client", "Spotify")
        ]
        var pausedCandidate: Snapshot?
        var permissionBlocked = false
        var firstFailure: String?
        var sawRunningApp = false

        for candidate in candidates where runningBundles.contains(candidate.bundle) {
            sawRunningApp = true
            // Different AppleScript dictionaries: Music does not recognize
            // Spotify's artwork URL term, even inside a conditional clause.
            let artworkScript = candidate.name == "Spotify" ? """
                try
                    set artAddress to artwork url of currentSong as text
                end try
            """ : ""
            let script = """
            tell application "\(candidate.name)"
                set playbackState to "stopped"
                if player state is playing then
                    set playbackState to "playing"
                else if player state is paused then
                    set playbackState to "paused"
                end if
                if playbackState is "stopped" then return "stopped"
                set currentSong to current track
                set trackPosition to player position as text
                set trackDuration to duration of currentSong as text
                set artAddress to ""
                \(artworkScript)
                set sep to ASCII character 30
                return playbackState & sep & (name of currentSong as text) & sep & (artist of currentSong as text) & sep & (album of currentSong as text) & sep & trackPosition & sep & trackDuration & sep & artAddress
            end tell
            """
            let result = runAppleScript(script)
            if result.code == -1743 {
                permissionBlocked = true
                continue
            }
            if let error = result.message {
                firstFailure = firstFailure ?? "\(candidate.name): \(error)"
            }
            guard let raw = result.value,
                  let snapshot = parseSnapshot(raw, player: candidate.name,
                                               bundle: candidate.bundle) else { continue }
            if snapshot.isPlaying {
                return PlayerLookup(snapshot: snapshot, message: "Playing in \(candidate.name)",
                                    automationDenied: false)
            }
            if pausedCandidate == nil { pausedCandidate = snapshot }
        }
        if let pausedCandidate {
            return PlayerLookup(snapshot: pausedCandidate,
                                message: "Paused in \(pausedCandidate.playerName)",
                                automationDenied: false)
        }
        if permissionBlocked {
            return PlayerLookup(snapshot: nil,
                                message: "Allow RelayOS to control Music or Spotify in System Settings → Privacy & Security → Automation.",
                                automationDenied: true)
        }
        if let firstFailure {
            return PlayerLookup(snapshot: nil,
                                message: "Unable to read playback: \(String(firstFailure.prefix(135)))",
                                automationDenied: false)
        }
        return PlayerLookup(snapshot: nil, message: sawRunningApp
                            ? "Music or Spotify is open, but not reporting a track."
                            : "No supported desktop player. Browser audio shown in Control Center is protected by macOS.",
                            automationDenied: false)
    }

    nonisolated private static func runAppleScript(_ source: String)
        -> (value: String?, code: Int?, message: String?) {
        guard let script = NSAppleScript(source: source) else {
            return (nil, nil, "AppleScript could not be prepared")
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            return (nil, error["NSAppleScriptErrorNumber"] as? Int,
                    error["NSAppleScriptErrorMessage"] as? String)
        }
        return (result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                nil, nil)
    }

}

/// Manages the persistent hardware-notch companion window.
/// Remains open even when the main RelayOS Settings window closes in the background.
@MainActor
final class NotchPanelCoordinator: ObservableObject {
    static let shared = NotchPanelCoordinator()
    private static let enabledDefaultsKey = "relayos.notch.enabled"
    private static let selectedSubpageDefaultsKey = "relayos.notch.selected-subpage"
    /// Keep the tray available long enough to cross from the top band into
    /// expanded controls without a jittery collapse/re-open cycle.
    static let hoverCollapseDelayMilliseconds = 700

    @Published private(set) var isVisible = false
    @Published private(set) var phase: NotchPanelPhase = .collapsed
    @Published var selectedSubpage: NotchSubpage {
        didSet {
            UserDefaults.standard.set(selectedSubpage.rawValue, forKey: Self.selectedSubpageDefaultsKey)
        }
    }

    private(set) var panel: RelayOSNotchWindow?
    private var model: BridgeModel?
    private var screenObserver: NSObjectProtocol?
    private var activeSpaceObserver: NSObjectProtocol?
    private var openMainWindow: (() -> Void)?
    private var pendingCollapse: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledDefaultsKey)
        }
    }

    var hasLiveActivity: Bool {
        let hasActiveJobs = model?.commandJobs.contains(where: \.active) ?? false
        let isMusicPlaying = NotchMediaController.shared.hasRunningPlayer && !NotchMediaController.shared.trackTitle.isEmpty
        let hasApprovals = model.map { $0.isSwiftOnly ? $0.nativePendingCount > 0 : !$0.approvalInbox.isEmpty } ?? false
        return hasActiveJobs || isMusicPlaying || hasApprovals
    }

    private init() {
        selectedSubpage = Self.restoredSubpage(from: UserDefaults.standard)
    }

    static func restoredSubpage(from defaults: UserDefaults) -> NotchSubpage {
        let saved = defaults.string(forKey: selectedSubpageDefaultsKey)
        return NotchSubpage(rawValue: saved ?? "") ?? .activity
    }

    func registerOpenMainWindow(_ handler: @escaping () -> Void) {
        self.openMainWindow = handler
    }

    func ensurePresentedOnLaunch(model: BridgeModel) {
        guard isEnabled else { return }
        present(model: model, openMainWindow: openMainWindow ?? Self.defaultOpenMainWindow)
    }

    func toggle(model: BridgeModel, openMainWindow: @escaping () -> Void) {
        if isVisible {
            isEnabled = false
            dismiss()
        } else {
            isEnabled = true
            present(model: model, openMainWindow: openMainWindow)
        }
    }

    func present(model: BridgeModel, openMainWindow: @escaping () -> Void) {
        self.model = model
        self.openMainWindow = openMainWindow
        isEnabled = true
        bindActivityObservers(model: model)
        NotchMediaController.shared.startMonitoring()

        if let panel, panel.isVisible {
            reposition()
            panel.orderFrontRegardless()
            return
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        phase = .collapsed
        let layout = NotchPanelPlacement.layout(
            for: screen,
            phase: phase,
            hasLiveActivity: hasLiveActivity
        )
        let window = RelayOSNotchWindow(
            contentRect: layout.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: NotchPanelView(
            model: model,
            coordinator: self,
            media: NotchMediaController.shared,
            onClose: { [weak self] in
                self?.isEnabled = false
                self?.dismiss()
            },
            onOpenMain: { [weak self] in
                self?.triggerOpenMainWindow()
            }
        ))
        window.installPointerTracking()
        panel = window
        window.orderFrontRegardless()
        isVisible = true

        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reposition() }
            }
        }
        if activeSpaceObserver == nil {
            activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    // Reassert the top-edge frame after a Space swipe. This
                    // also prevents AppKit retaining an old cloned frame.
                    self?.reposition(animated: false)
                    self?.panel?.orderFrontRegardless()
                }
            }
        }
    }

    private func bindActivityObservers(model: BridgeModel) {
        cancellables.removeAll()

        model.$commandJobs
            .map { $0.contains(where: \.active) }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reposition(animated: true)
            }
            .store(in: &cancellables)

        NotchMediaController.shared.$isPlaying
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reposition(animated: true)
            }
            .store(in: &cancellables)

        model.$approvalInbox
            .map { !$0.isEmpty }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reposition(animated: true) }
            .store(in: &cancellables)

        model.$nativePendingCount
            .map { $0 > 0 }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reposition(animated: true) }
            .store(in: &cancellables)
    }

    func triggerOpenMainWindow() {
        if let openMainWindow {
            openMainWindow()
        }
        Self.defaultOpenMainWindow()
    }

    private static func defaultOpenMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let mainWindow = NSApp.windows.first(where: {
            !($0 is RelayOSNotchWindow) && ($0.title == "RelayOS" || $0.identifier?.rawValue == "main")
        }) {
            mainWindow.makeKeyAndOrderFront(nil)
        }
    }

    func hover(_ hovering: Bool) {
        guard isVisible else { return }
        pendingCollapse?.cancel()
        pendingCollapse = nil
        if hovering {
            if phase == .collapsed {
                transition(to: .hovered, haptic: true)
            }
        } else {
            pendingCollapse = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Self.hoverCollapseDelayMilliseconds))
                guard !Task.isCancelled, let self else { return }
                // Account for a fast pointer passing across the changing
                // frame while the panel is expanding or collapsing.
                if self.panel?.frame.insetBy(dx: -12, dy: -12)
                    .contains(NSEvent.mouseLocation) == true { return }
                self.collapse()
            }
        }
    }

    func expand() {
        guard isVisible, phase != .expanded else { return }
        pendingCollapse?.cancel()
        pendingCollapse = nil
        let hasApprovals = model.map { $0.isSwiftOnly ? $0.nativePendingCount > 0 : !$0.approvalInbox.isEmpty } ?? false
        if hasApprovals {
            selectedSubpage = .approvals
            transition(to: .expanded, haptic: true)
            return
        }
        let hasActiveJobs = model?.commandJobs.contains(where: \.active) ?? false
        // Prefer an active terminal job when one exists. Otherwise retain the
        // user's page choice, except for the first music activity after launch.
        if !hasActiveJobs && NotchMediaController.shared.hasRunningPlayer,
           UserDefaults.standard.object(forKey: Self.selectedSubpageDefaultsKey) == nil {
            selectedSubpage = .music
        }
        transition(to: .expanded, haptic: true)
    }

    func collapse() {
        pendingCollapse?.cancel()
        pendingCollapse = nil
        guard isVisible, phase != .collapsed else { return }
        transition(to: .collapsed, haptic: false)
    }

    private func transition(to next: NotchPanelPhase, haptic: Bool) {
        guard panel != nil else { return }
        phase = next
        if haptic {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
        reposition(animated: true)
    }

    func reposition(animated: Bool = false) {
        guard let panel, let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        let layout = NotchPanelPlacement.layout(
            for: screen,
            phase: phase,
            hasLiveActivity: hasLiveActivity
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(layout.frame, display: true)
            }
        } else {
            panel.setFrame(layout.frame, display: true)
        }
    }

    func dismiss() {
        pendingCollapse?.cancel()
        pendingCollapse = nil
        cancellables.removeAll()
        NotchMediaController.shared.stopMonitoring()
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        phase = .collapsed
        isVisible = false
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
            self.activeSpaceObserver = nil
        }
    }
}

struct NotchPanelView: View {
    @ObservedObject var model: BridgeModel
    @ObservedObject var coordinator: NotchPanelCoordinator
    @ObservedObject var media: NotchMediaController = .shared
    let onClose: () -> Void
    let onOpenMain: () -> Void

    /// Preview-only overrides keep every Canvas preview next to its view.
    var previewLayout: NotchPanelPlacement.Layout? = nil
    var previewPhase: NotchPanelPhase? = nil
    var previewSubpage: NotchSubpage? = nil
    private var displayedSubpage: NotchSubpage { previewSubpage ?? coordinator.selectedSubpage }

    private var phase: NotchPanelPhase { previewPhase ?? coordinator.phase }
    private var jobs: [CommandJobEntry] {
        model.commandJobs.filter(\.active).sorted {
            if $0.status != $1.status { return $0.status == "running" }
            return $0.createdAt > $1.createdAt
        }
    }
    private var primaryJob: CommandJobEntry? { jobs.first }
    private var isRunningJob: Bool { !jobs.isEmpty }
    private var isPlayingMusic: Bool { media.isPlaying }
    private var hasMusicTrack: Bool { media.hasRunningPlayer && !media.trackTitle.isEmpty }
    private var hasLiveActivity: Bool { isRunningJob || hasMusicTrack || pendingApprovalsCount > 0 }
    private var pendingApprovalsCount: Int {
        model.isSwiftOnly ? model.nativePendingCount : model.approvalInbox.count
    }

    private var layout: NotchPanelPlacement.Layout {
        if let previewLayout { return previewLayout }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return NotchPanelPlacement.layout(
                displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
                hardwareNotchWidth: 185,
                phase: phase,
                hasLiveActivity: hasLiveActivity
            )
        }
        return NotchPanelPlacement.layout(
            for: screen,
            phase: phase,
            hasLiveActivity: hasLiveActivity
        )
    }

    private let muted = Color.white.opacity(0.62)
    private var visibleTabs: [NotchSubpage] {
        var tabs: [NotchSubpage] = [.activity]
        if pendingApprovalsCount > 0 || displayedSubpage == .approvals { tabs.append(.approvals) }
        tabs += [.music, .services]
        return tabs
    }

    var body: some View {
        let shape = NotchShape(
            topCornerRadius: layout.topCornerRadius,
            bottomCornerRadius: layout.bottomCornerRadius
        )

        VStack(spacing: 0) {
            topBand
                .frame(height: layout.topBandHeight)

            if phase == .expanded {
                expandedTray
                    .frame(height: phase.trayHeight)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if phase == .hovered {
                // Subtle empty hover expansion space; no idle text clutter.
                Color.clear
                    .frame(height: phase.trayHeight)
            }
        }
        .padding(.horizontal, layout.topCornerRadius)
        .frame(width: layout.frame.width, height: layout.frame.height, alignment: .top)
        .background(Color.black, in: shape)
        .clipShape(shape)
        .overlay {
            if phase == .expanded {
                shape
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(shape)
        .onTapGesture {
            if phase != .expanded {
                coordinator.expand()
            }
        }
        .onHover { hovering in
            if previewPhase == nil { coordinator.hover(hovering) }
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .animation(.spring(response: 0.24, dampingFraction: 0.84), value: phase)
        .animation(.spring(response: 0.24, dampingFraction: 0.84), value: hasLiveActivity)
        .animation(.easeInOut(duration: 0.16), value: displayedSubpage)
    }

    @ViewBuilder
    private var topBand: some View {
        if phase == .expanded {
            expandedTopBand
        } else if layout.hasLiveActivity {
            liveActivityTopBand
        } else {
            // Idle collapsed & idle hovered: pure black hardware-notch silhouette with nothing drawn on it.
            Color.black
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .accessibilityLabel("RelayOS Notch. Click to expand.")
        }
    }

    private var liveActivityTopBand: some View {
        Button {
            coordinator.expand()
        } label: {
            HStack(spacing: 0) {
                // Left live-activity wing
                HStack(spacing: 6) {
                    if pendingApprovalsCount > 0 {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.orange)
                        Text("Approval request")
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(1)
                    } else if isRunningJob {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green)
                        Text(primaryJob?.executableName ?? "Running")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                    } else if hasMusicTrack {
                        Image(systemName: media.isPlaying ? "waveform" : "pause.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.pink)
                        Text(media.trackTitle.isEmpty ? media.playerName : media.trackTitle)
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .frame(width: layout.leftWidth)

                // Hardware camera exclusion zone
                Color.black
                    .frame(width: layout.centerGap)
                    .accessibilityHidden(true)

                // Right live-activity wing
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    if pendingApprovalsCount > 0 {
                        Text("\(pendingApprovalsCount) waiting")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.orange)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.orange)
                    } else if let job = primaryJob {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(CommandJobProgress.elapsedLabel(job, at: context.date))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.green)
                        }
                        if jobs.count > 1 {
                            Text("+\(jobs.count - 1)")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.14), in: Capsule())
                        }
                    } else if hasMusicTrack {
                        Text(media.artistName.isEmpty ? (media.isPlaying ? "Playing" : "Paused") : media.artistName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(muted)
                            .lineLimit(1)
                        Image(systemName: "music.note")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.pink)
                    }
                }
                .padding(.leading, 4)
                .padding(.trailing, 8)
                .frame(width: layout.rightWidth)
            }
            .frame(maxHeight: .infinity)
            .foregroundStyle(.white)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var expandedTopBand: some View {
        HStack(spacing: 0) {
            // Left header ear: RelayOS identity & health
            Button {
                openControlCenter()
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill((model.mcpHealth == .healthy || model.running) ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text("RelayOS")
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                    if pendingApprovalsCount > 0 {
                        Text("\(pendingApprovalsCount)")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange, in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 10)
                .frame(width: layout.leftWidth, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Center camera exclusion gap
            Color.black
                .frame(width: layout.centerGap)
                .accessibilityHidden(true)

            // Right header ear: Sub-page tabs + Collapse button
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                ForEach(visibleTabs) { page in
                    Button {
                        coordinator.selectedSubpage = page
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: page.icon)
                                .font(.system(size: 9.5, weight: .semibold))
                            Text(page.title)
                                .font(.system(size: 9.5, weight: .semibold))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            displayedSubpage == page
                                ? Color.white.opacity(0.18)
                                : Color.white.opacity(0.05),
                            in: Capsule()
                        )
                        .foregroundStyle(displayedSubpage == page ? .white : muted)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    coordinator.collapse()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.08), in: Circle())
                        .foregroundStyle(muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse notch")
            }
            .padding(.trailing, 8)
            .frame(width: layout.rightWidth, alignment: .trailing)
        }
        .frame(maxHeight: .infinity)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var expandedTray: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(Color.white.opacity(0.08))
                .padding(.horizontal, 12)

            Group {
                switch displayedSubpage {
                case .activity:
                    activitySubpageView
                case .approvals:
                    approvalsSubpageView
                case .music:
                    musicSubpageView
                case .services:
                    servicesSubpageView
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(.white)
    }

    private var activitySubpageView: some View {
        HStack(spacing: 10) {
            // Terminal Jobs card
            Button(action: openTerminalJobs) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(isRunningJob ? Color.green.opacity(0.18) : Color.white.opacity(0.07))
                            .frame(width: 36, height: 36)
                        Image(systemName: isRunningJob ? "terminal.fill" : "checkmark.circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(isRunningJob ? Color.green : muted)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(isRunningJob
                             ? (primaryJob?.executableName ?? "\(jobs.count) active job\(jobs.count == 1 ? "" : "s")")
                             : "Terminal Jobs")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(primaryJob.map {
                            URL(fileURLWithPath: $0.projectRoot).lastPathComponent + " · " + $0.status.capitalized
                        } ?? (model.commandJobs.isEmpty ? "No running commands" : "\(model.commandJobs.count) recorded in history"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(muted)
                            .lineLimit(1)
                        if let job = primaryJob {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text("Elapsed " + CommandJobProgress.elapsedLabel(job, at: context.date))
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(muted)
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Approvals card
            Button(action: openApprovals) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "tray.full.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(pendingApprovalsCount > 0 ? Color.orange : muted)
                        Spacer()
                        if pendingApprovalsCount > 0 {
                            Text("\(pendingApprovalsCount)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange, in: Capsule())
                        } else {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(muted)
                        }
                    }
                    Spacer(minLength: 0)
                    Text("Approvals")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(pendingApprovalsCount > 0
                         ? "\(pendingApprovalsCount) waiting review"
                         : "All clear")
                        .font(.system(size: 10))
                        .foregroundStyle(muted)
                        .lineLimit(1)
                }
                .padding(10)
                .frame(width: 145)
                .frame(maxHeight: .infinity)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var approvalsSubpageView: some View {
        if let item = model.approvalInbox.first, !model.isSwiftOnly {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.isOAuth ? "Connection approval" : "Command approval")
                            .font(.system(size: 11.5, weight: .bold))
                        Text(item.title)
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .foregroundStyle(muted)
                    }
                    Spacer(minLength: 0)
                    Text("\(pendingApprovalsCount) pending")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.orange)
                }

                Text(item.scopeDescription)
                    .font(.system(size: 9.5))
                    .foregroundStyle(muted)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    approvalButton("Once", icon: "checkmark", color: .green) {
                        model.decideApproval(item, decision: "once")
                    }
                    if !item.isOAuth {
                        approvalButton("Session", icon: "clock", color: .blue) {
                            model.decideApproval(item, decision: "session")
                        }
                        approvalButton("Always", icon: "infinity", color: .purple) {
                            model.decideApproval(item, decision: "persistent")
                        }
                    }
                    approvalButton("Deny", icon: "xmark", color: .red) {
                        model.decideApproval(item, decision: "deny")
                    }
                }
                .disabled(item.isExpired || model.approvalDecisionInFlight != nil)
            }
            .padding(.horizontal, 4)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 22))
                    .foregroundStyle(muted)
                Text(model.isSwiftOnly && pendingApprovalsCount > 0
                     ? "Open RelayOS to review this native request"
                     : "No pending approvals")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(muted)
                if model.isSwiftOnly && pendingApprovalsCount > 0 {
                    Button("Open approvals", action: openApprovals)
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func approvalButton(
        _ title: String, icon: String, color: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(color.opacity(0.20), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
    }

    private var musicSubpageView: some View {
        NotchMusicControlsView(media: media)
    }

    private var servicesSubpageView: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill((model.mcpHealth == .healthy || model.running) ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text("Local MCP: \((model.mcpHealth == .healthy || model.running) ? "Healthy" : "Stopped")")
                        .font(.system(size: 11, weight: .semibold))
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.tunnelHealth == .healthy ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text("Public MCP: \(model.tunnelHealth == .healthy ? "Verified" : model.tunnelHealth.label)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(muted)
                        .lineLimit(1)
                }
                if !model.connectedClients.isEmpty {
                    Text("\(model.connectedClients.count) client(s) connected")
                        .font(.system(size: 9.5))
                        .foregroundStyle(muted)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

            VStack(spacing: 6) {
                Button {
                    model.copyEndpoint()
                } label: {
                    Label("Copy URL", systemImage: "doc.on.doc")
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .disabled(model.endpoint == "Not configured")

                HStack(spacing: 6) {
                    Button {
                        openControlCenter()
                    } label: {
                        Label("Settings", systemImage: "gearshape.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)

                    Button(action: onClose) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 10.5, weight: .semibold))
                            .frame(width: 32)
                            .frame(maxHeight: .infinity)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                            .foregroundStyle(muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide notch")
                }
            }
            .frame(width: 170)
        }
    }

    private func openTerminalJobs() {
        if let job = primaryJob { model.selectCommandJob(job.id) }
        if model.isSwiftOnly { model.showApprovalCenter() }
        else { model.showTerminalJobs() }
        onOpenMain()
        coordinator.collapse()
    }

    private func openApprovals() {
        model.showApprovalCenter()
        onOpenMain()
        coordinator.collapse()
    }

    private func openControlCenter() {
        onOpenMain()
        coordinator.collapse()
    }
}

// Self-contained playback control layout avoids inflating the parent notch
// view's SwiftUI type graph. Only metadata and transport controls are shown.
struct NotchMusicControlsView: View {
    @ObservedObject var media: NotchMediaController
    @State private var isScrubbingMusic = false
    @State private var draggedMusicPosition: Double = 0
    private let muted = Color.white.opacity(0.62)

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 11) {
                albumArtwork
                    .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 3) {
                    Text(media.trackTitle.isEmpty ? "Nothing playing" : media.trackTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(media.artistName.isEmpty
                         ? media.sourceMessage
                         : (media.albumName.isEmpty
                            ? media.artistName
                            : "\(media.artistName) · \(media.albumName)"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(muted)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: "music.note")
                            .font(.system(size: 8))
                        Text(media.hasRunningPlayer ? media.playerName : "Apple Music · Spotify")
                            .lineLimit(1)
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.48))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                playbackButtons
            }

            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                VStack(spacing: 3) {
                    if let duration = media.duration, duration > 0 {
                        Slider(
                            value: Binding(
                                get: {
                                    isScrubbingMusic
                                        ? draggedMusicPosition
                                        : (media.position(at: context.date) ?? 0)
                                },
                                set: { draggedMusicPosition = $0 }
                            ),
                            in: 0...duration,
                            onEditingChanged: { editing in
                                if editing {
                                    draggedMusicPosition = media.position(at: context.date) ?? 0
                                    isScrubbingMusic = true
                                } else {
                                    isScrubbingMusic = false
                                    media.seek(to: draggedMusicPosition)
                                }
                            }
                        )
                        .tint(.pink)
                        .disabled(media.commandInFlight)
                        .accessibilityLabel("Playback position")
                        .accessibilityValue(
                            NotchPlaybackTimeline.clock(
                                isScrubbingMusic ? draggedMusicPosition
                                    : media.position(at: context.date)
                            )
                        )
                    } else {
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                            .frame(height: 3)
                            .accessibilityLabel("Playback progress unavailable")
                    }

                    HStack {
                        Text(NotchPlaybackTimeline.clock(
                            isScrubbingMusic ? draggedMusicPosition
                                : media.position(at: context.date)))
                        Spacer()
                        Text(NotchPlaybackTimeline.clock(media.duration))
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(muted)
                }
            }
            HStack(spacing: 9) {
                RelayOSAirPlayPicker()
                    .frame(width: 27, height: 24)
                    .help("Native AirPlay chooser for RelayOS-owned playback, not a system-wide audio switch")
                    .accessibilityLabel("AirPlay destinations")

                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("System output", systemImage: "hifispeaker")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Change the Mac's default sound output, including supported AirPlay devices")

                Spacer(minLength: 0)

                if !media.hasRunningPlayer {
                    if !RelayOSMediaKeys.isAuthorized {
                        Button("Enable media keys") {
                            media.requestMediaKeyAccess()
                        }
                        .font(.system(size: 10))
                        .buttonStyle(.plain)
                    }
                    Button {
                        Task { await media.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Refresh supported playback metadata")
                }
            }
            .foregroundStyle(muted)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var albumArtwork: some View {
        Group {
            if let url = media.artworkURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    artworkPlaceholder
                }
            } else {
                artworkPlaceholder
            }
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityLabel("Track artwork")
    }

    private var artworkPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(LinearGradient(
                    colors: [Color.pink.opacity(0.65), Color.purple.opacity(0.52)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: media.isPlaying ? "waveform" : "music.note")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    private var playbackButtons: some View {
        HStack(spacing: 7) {
            Button {
                media.previousTrack()
            } label: {
                Image(systemName: "backward.end.fill")
                    .frame(width: 27, height: 30)
            }
            .accessibilityLabel("Previous track")

            Button {
                media.togglePlayPause()
            } label: {
                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 33, height: 33)
                    .background(Color.white.opacity(0.18), in: Circle())
            }
            .accessibilityLabel(media.isPlaying ? "Pause" : "Play")

            Button {
                media.nextTrack()
            } label: {
                Image(systemName: "forward.end.fill")
                    .frame(width: 27, height: 30)
            }
            .accessibilityLabel("Next track")
        }
        .font(.system(size: 11))
        .buttonStyle(.plain)
        .disabled(!media.hasRunningPlayer || media.commandInFlight)
    }

}



#if DEBUG
#Preview("Music · Not Playing") {
    NotchMusicControlsView(media: .shared)
        .frame(width: 490, height: 146)
        .padding(16)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 18))
}
#endif

#if DEBUG
#Preview("Notch · Idle Collapsed") {
    NotchPanelView(
        model: BridgeModel.preview(),
        coordinator: .shared,
        onClose: {},
        onOpenMain: {},
        previewLayout: NotchPanelPlacement.layout(
            displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            hardwareNotchWidth: 185,
            phase: .collapsed,
            hasLiveActivity: false
        ),
        previewPhase: .collapsed
    )
    .padding(24)
    .background(Color.gray.opacity(0.25))
}

#Preview("Notch · Live Activity Collapsed") {
    NotchPanelView(
        model: BridgeModel.preview(),
        coordinator: .shared,
        onClose: {},
        onOpenMain: {},
        previewLayout: NotchPanelPlacement.layout(
            displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            hardwareNotchWidth: 185,
            phase: .collapsed,
            hasLiveActivity: true
        ),
        previewPhase: .collapsed
    )
    .padding(24)
    .background(Color.gray.opacity(0.25))
}

#Preview("Notch · Hover") {
    NotchPanelView(
        model: BridgeModel.preview(),
        coordinator: .shared,
        onClose: {},
        onOpenMain: {},
        previewLayout: NotchPanelPlacement.layout(
            displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            hardwareNotchWidth: 185,
            phase: .hovered,
            hasLiveActivity: false
        ),
        previewPhase: .hovered
    )
    .padding(24)
    .background(Color.gray.opacity(0.25))
}

#Preview("Notch · Expanded") {
    NotchPanelView(
        model: BridgeModel.preview(),
        coordinator: .shared,
        onClose: {},
        onOpenMain: {},
        previewLayout: NotchPanelPlacement.layout(
            displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            hardwareNotchWidth: 185,
            phase: .expanded,
            hasLiveActivity: true
        ),
        previewPhase: .expanded
    )
    .padding(24)
    .background(Color.gray.opacity(0.25))
}
#endif
