// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Views/QuickPanel/NotchPanel.swift
import AppKit
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
        case .expanded: 138
        }
    }
}

/// Extensible sub-pages hosted inside the expanded notch tray.
enum NotchSubpage: String, CaseIterable, Identifiable {
    case activity
    case music
    case services

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activity: "Activity"
        case .music: "Music"
        case .services: "System"
        }
    }

    var icon: String {
        switch self {
        case .activity: "terminal.fill"
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
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]
        // Make the notch completely invisible in screenshots and screen recordings.
        sharingType = .none
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
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

/// Monitors and controls live music playback in Apple Music or Spotify without
/// launching player applications that are not already running.
@MainActor
final class NotchMediaController: ObservableObject {
    static let shared = NotchMediaController()

    @Published private(set) var isPlaying = false
    @Published private(set) var trackTitle = ""
    @Published private(set) var artistName = ""
    @Published private(set) var albumName = ""
    @Published private(set) var playerName = "Music"
    @Published private(set) var playerBundleIdentifier = "com.apple.Music"

    private var pollTask: Task<Void, Never>?

    struct Snapshot: Sendable, Equatable {
        let isPlaying: Bool
        let trackTitle: String
        let artistName: String
        let albumName: String
        let playerName: String
        let playerBundleIdentifier: String
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
        let runningBundles = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        let snapshot = await Task.detached(priority: .utility) {
            Self.queryRunningPlayers(runningBundles: runningBundles)
        }.value

        if let snapshot {
            if isPlaying != snapshot.isPlaying { isPlaying = snapshot.isPlaying }
            if trackTitle != snapshot.trackTitle { trackTitle = snapshot.trackTitle }
            if artistName != snapshot.artistName { artistName = snapshot.artistName }
            if albumName != snapshot.albumName { albumName = snapshot.albumName }
            if playerName != snapshot.playerName { playerName = snapshot.playerName }
            if playerBundleIdentifier != snapshot.playerBundleIdentifier {
                playerBundleIdentifier = snapshot.playerBundleIdentifier
            }
        } else if isPlaying || !trackTitle.isEmpty {
            isPlaying = false
            trackTitle = ""
            artistName = ""
            albumName = ""
        }
    }

    func togglePlayPause() {
        let targetApp = activeOrPreferredAppName()
        Task.detached(priority: .userInitiated) {
            _ = Self.runAppleScript("tell application \"\(targetApp)\" to playpause")
            await self.refresh()
        }
    }

    func nextTrack() {
        let targetApp = activeOrPreferredAppName()
        Task.detached(priority: .userInitiated) {
            _ = Self.runAppleScript("tell application \"\(targetApp)\" to next track")
            try? await Task.sleep(for: .milliseconds(180))
            await self.refresh()
        }
    }

    func previousTrack() {
        let targetApp = activeOrPreferredAppName()
        Task.detached(priority: .userInitiated) {
            _ = Self.runAppleScript("tell application \"\(targetApp)\" to previous track")
            try? await Task.sleep(for: .milliseconds(180))
            await self.refresh()
        }
    }

    func openPlayerApp() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: playerBundleIdentifier) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else if let musicURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") {
            NSWorkspace.shared.openApplication(at: musicURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    #if DEBUG
    func applyPreviewState(
        isPlaying: Bool,
        trackTitle: String = "",
        artistName: String = "",
        playerName: String = "Music"
    ) {
        self.isPlaying = isPlaying
        self.trackTitle = trackTitle
        self.artistName = artistName
        self.playerName = playerName
    }
    #endif

    private func activeOrPreferredAppName() -> String {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if running.contains(playerBundleIdentifier) {
            return playerName
        }
        if running.contains("com.spotify.client") {
            return "Spotify"
        }
        return "Music"
    }

    nonisolated private static func queryRunningPlayers(runningBundles: Set<String>) -> Snapshot? {
        let candidates: [(bundle: String, name: String)] = [
            ("com.apple.Music", "Music"),
            ("com.spotify.client", "Spotify")
        ]
        var pausedCandidate: Snapshot?

        for candidate in candidates where runningBundles.contains(candidate.bundle) {
            let script = """
            tell application "\(candidate.name)"
                if player state is playing then
                    return "playing||" & (name of current track) & "||" & (artist of current track) & "||" & (album of current track)
                else if player state is paused then
                    return "paused||" & (name of current track) & "||" & (artist of current track) & "||" & (album of current track)
                else
                    return "stopped||||||"
                end if
            end tell
            """
            guard let raw = runAppleScript(script), !raw.isEmpty else { continue }
            let parts = raw.components(separatedBy: "||")
            guard let state = parts.first else { continue }
            let title = parts.count > 1 ? parts[1] : ""
            let artist = parts.count > 2 ? parts[2] : ""
            let album = parts.count > 3 ? parts[3] : ""
            let snapshot = Snapshot(
                isPlaying: state == "playing",
                trackTitle: title,
                artistName: artist,
                albumName: album,
                playerName: candidate.name,
                playerBundleIdentifier: candidate.bundle
            )
            if snapshot.isPlaying {
                return snapshot
            }
            if state == "paused", !title.isEmpty, pausedCandidate == nil {
                pausedCandidate = snapshot
            }
        }
        return pausedCandidate
    }

    nonisolated private static func runAppleScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}

/// Manages the persistent hardware-notch companion window.
/// Remains open even when the main RelayOS Settings window closes in the background.
@MainActor
final class NotchPanelCoordinator: ObservableObject {
    static let shared = NotchPanelCoordinator()
    private static let enabledDefaultsKey = "relayos.notch.enabled"

    @Published private(set) var isVisible = false
    @Published private(set) var phase: NotchPanelPhase = .collapsed
    @Published var selectedSubpage: NotchSubpage = .activity

    private(set) var panel: RelayOSNotchWindow?
    private var model: BridgeModel?
    private var screenObserver: NSObjectProtocol?
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
        let isMusicPlaying = NotchMediaController.shared.isPlaying
        return hasActiveJobs || isMusicPlaying
    }

    private init() {}

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
            let delayMs = phase == .expanded ? 280 : 150
            pendingCollapse = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(delayMs))
                guard !Task.isCancelled, let self else { return }
                if self.panel?.frame.insetBy(dx: -3, dy: -3)
                    .contains(NSEvent.mouseLocation) == true { return }
                self.collapse()
            }
        }
    }

    func expand() {
        guard isVisible, phase != .expanded else { return }
        pendingCollapse?.cancel()
        pendingCollapse = nil
        let hasActiveJobs = model?.commandJobs.contains(where: \.active) ?? false
        if !hasActiveJobs && NotchMediaController.shared.isPlaying {
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
    private var hasLiveActivity: Bool { isRunningJob || isPlayingMusic }
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
        .animation(.easeInOut(duration: 0.16), value: coordinator.selectedSubpage)
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
                    if isRunningJob {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green)
                        Text(primaryJob?.executableName ?? "Running")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                    } else if isPlayingMusic {
                        Image(systemName: "waveform")
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
                    if let job = primaryJob {
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
                    } else if isPlayingMusic {
                        Text(media.artistName.isEmpty ? "Playing" : media.artistName)
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
                ForEach(NotchSubpage.allCases) { page in
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
                            coordinator.selectedSubpage == page
                                ? Color.white.opacity(0.18)
                                : Color.white.opacity(0.05),
                            in: Capsule()
                        )
                        .foregroundStyle(coordinator.selectedSubpage == page ? .white : muted)
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
                switch coordinator.selectedSubpage {
                case .activity:
                    activitySubpageView
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

    private var musicSubpageView: some View {
        HStack(spacing: 12) {
            Button {
                media.openPlayerApp()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: isPlayingMusic
                                    ? [Color.pink.opacity(0.85), Color.purple.opacity(0.75)]
                                    : [Color.white.opacity(0.12), Color.white.opacity(0.06)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 52, height: 52)
                    Image(systemName: isPlayingMusic ? "waveform" : "music.note")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(media.trackTitle.isEmpty ? "Not Playing" : media.trackTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(media.artistName.isEmpty
                     ? "Play in Apple Music or Spotify"
                     : (media.albumName.isEmpty ? media.artistName : "\(media.artistName) — \(media.albumName)"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(muted)
                    .lineLimit(1)
                Text(media.playerName)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(isPlayingMusic ? Color.pink : muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button {
                    media.previousTrack()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous track")

                Button {
                    media.togglePlayPause()
                } label: {
                    Image(systemName: isPlayingMusic ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 38, height: 38)
                        .background(Color.white.opacity(0.18), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlayingMusic ? "Pause" : "Play")

                Button {
                    media.nextTrack()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next track")
            }
        }
        .padding(.horizontal, 6)
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
