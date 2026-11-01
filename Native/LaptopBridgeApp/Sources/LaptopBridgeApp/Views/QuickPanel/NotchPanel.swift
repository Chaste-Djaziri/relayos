// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Views/QuickPanel/NotchPanel.swift
import AppKit
import SwiftUI

enum NotchPanelPhase: CaseIterable {
    case collapsed, hovered, expanded

    var trayHeight: CGFloat {
        switch self {
        case .collapsed: 0
        case .hovered: 28
        case .expanded: 94
        }
    }
}

/// The physical camera region is filled with black, but deliberately has no
/// text, icons, or interactive controls. The entire shape is one black surface.
enum NotchPanelPlacement {
    struct Layout {
        let frame: CGRect
        let topBandHeight: CGFloat
        let centerGap: CGFloat
        let leftWidth: CGFloat
        let rightWidth: CGFloat
        let hasHardwareNotch: Bool
        let phase: NotchPanelPhase
    }

    static let preferredWidth: CGFloat = 568
    static let trayHeight: CGFloat = 94

    static func layout(displayFrame: CGRect, visibleFrame: CGRect,
                       hardwareNotchWidth: CGFloat? = nil,
                       phase: NotchPanelPhase = .collapsed) -> Layout {
        let menuBand = max(0, displayFrame.maxY - visibleFrame.maxY)
        let hasNotch = (hardwareNotchWidth ?? 0) > 60 && menuBand > 15
        let topHeight = hasNotch ? min(max(30, menuBand), 42) : 38
        let minGap = max((hardwareNotchWidth ?? 190) + 18, 205)
        let requestedWidth: CGFloat
        switch phase {
        case .collapsed: requestedWidth = max(394, minGap + 185)
        case .hovered: requestedWidth = max(474, minGap + 255)
        case .expanded: requestedWidth = max(preferredWidth, minGap + 305)
        }
        let width = max(1, min(requestedWidth, visibleFrame.width - 24))
        let gap = min(minGap, max(1, width - 140))
        let sides = max(0, width - gap)
        let left = sides * (phase == .collapsed ? 0.43 : 0.44)
        let right = sides - left
        let height = topHeight + phase.trayHeight
        let topEdge = hasNotch ? displayFrame.maxY : visibleFrame.maxY - 8
        return Layout(
            frame: CGRect(x: visibleFrame.midX - width / 2,
                          y: max(visibleFrame.minY + 8, topEdge - height),
                          width: width, height: height),
            topBandHeight: topHeight, centerGap: gap,
            leftWidth: left, rightWidth: right,
            hasHardwareNotch: hasNotch, phase: phase
        )
    }

    static func layout(for screen: NSScreen,
                       phase: NotchPanelPhase = .collapsed) -> Layout {
        let gap: CGFloat?
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           left.width > 0, right.width > 0, right.minX > left.maxX {
            gap = right.minX - left.maxX
        } else {
            gap = nil
        }
        return layout(displayFrame: screen.frame, visibleFrame: screen.visibleFrame,
                      hardwareNotchWidth: gap, phase: phase)
    }
}

private final class RelayOSNotchWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        NotchPanelCoordinator.shared.collapse()
    }
}

/// The user explicitly enables this panel through the menu bar or Settings.
/// Hover and click transitions only change this panel; they never restart MCP.
@MainActor
final class NotchPanelCoordinator: ObservableObject {
    static let shared = NotchPanelCoordinator()

    @Published private(set) var isVisible = false
    @Published private(set) var phase: NotchPanelPhase = .collapsed

    private var panel: NSPanel?
    private var model: BridgeModel?
    private var screenObserver: NSObjectProtocol?
    private var openMainWindow: (() -> Void)?
    private var pendingCollapse: Task<Void, Never>?

    private init() {}

    func toggle(model: BridgeModel, openMainWindow: @escaping () -> Void) {
        if isVisible { dismiss() }
        else { present(model: model, openMainWindow: openMainWindow) }
    }

    func present(model: BridgeModel, openMainWindow: @escaping () -> Void) {
        self.model = model
        self.openMainWindow = openMainWindow
        if let panel, panel.isVisible {
            reposition()
            panel.orderFrontRegardless()
            return
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        phase = .collapsed
        let layout = NotchPanelPlacement.layout(for: screen)
        let window = RelayOSNotchWindow(
            contentRect: layout.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        window.isFloatingPanel = true
        window.level = layout.hasHardwareNotch ? .statusBar : .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = false
        window.contentView = NSHostingView(rootView: NotchPanelView(
            model: model, coordinator: self,
            onClose: { [weak self] in self?.dismiss() },
            onOpenMain: { [weak self] in self?.openMainWindow?() }
        ))
        panel = window
        window.orderFrontRegardless()
        isVisible = true
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reposition() }
            }
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
            // Grace prevents jitter while the NSPanel changes width/height.
            pendingCollapse = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled, let self else { return }
                // Resizing an NSPanel may briefly emit hover(false) even
                // though the cursor is still within its new frame.
                if self.panel?.frame.insetBy(dx: -2, dy: -2)
                    .contains(NSEvent.mouseLocation) == true { return }
                self.collapse()
            }
        }
    }

    func expand() {
        guard isVisible, phase != .expanded else { return }
        pendingCollapse?.cancel()
        pendingCollapse = nil
        transition(to: .expanded, haptic: true)
    }

    func collapse() {
        pendingCollapse?.cancel()
        pendingCollapse = nil
        guard isVisible, phase != .collapsed else { return }
        transition(to: .collapsed, haptic: false)
    }

    private func transition(to next: NotchPanelPhase, haptic: Bool) {
        guard let panel else { return }
        phase = next
        if haptic {
            // macOS provides feedback where the trackpad/device supports it.
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        reposition(animated: true)
    }

    func reposition(animated: Bool = false) {
        guard let panel, let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        let layout = NotchPanelPlacement.layout(for: screen, phase: phase)
        panel.level = layout.hasHardwareNotch ? .statusBar : .floating
        panel.setFrame(layout.frame, display: true, animate: animated)
    }

    func dismiss() {
        pendingCollapse?.cancel()
        pendingCollapse = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        model = nil
        openMainWindow = nil
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
    let onClose: () -> Void
    let onOpenMain: () -> Void

    /// Preview-only overrides keep every Canvas preview next to its view.
    var previewLayout: NotchPanelPlacement.Layout? = nil
    var previewPhase: NotchPanelPhase? = nil

    private var phase: NotchPanelPhase { previewPhase ?? coordinator.phase }
    private var layout: NotchPanelPlacement.Layout {
        if let previewLayout { return previewLayout }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return NotchPanelPlacement.layout(
                displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
                hardwareNotchWidth: 190, phase: phase)
        }
        return NotchPanelPlacement.layout(for: screen, phase: phase)
    }

    private var jobs: [CommandJobEntry] {
        model.commandJobs.filter(\.active).sorted {
            if $0.status != $1.status { return $0.status == "running" }
            return $0.createdAt > $1.createdAt
        }
    }
    private var primaryJob: CommandJobEntry? { jobs.first }
    private var isRunning: Bool { !jobs.isEmpty }
    private let muted = Color.white.opacity(0.62)

    var body: some View {
        VStack(spacing: 0) {
            topBand
                .frame(height: layout.topBandHeight)

            if phase == .hovered {
                hoverStrip
                    .frame(height: phase.trayHeight)
                    .transition(.opacity)
            } else if phase == .expanded {
                expandedTray
                    .frame(height: phase.trayHeight)
                    .transition(.opacity)
            }
        }
        .frame(width: layout.frame.width, height: layout.frame.height)
        .background(
            Color.black,
            in: UnevenRoundedRectangle(
                topLeadingRadius: 10,
                bottomLeadingRadius: phase == .collapsed ? 13 : 18,
                bottomTrailingRadius: phase == .collapsed ? 13 : 18,
                topTrailingRadius: 10
            )
        )
        .overlay {
            UnevenRoundedRectangle(
                topLeadingRadius: 10,
                bottomLeadingRadius: phase == .collapsed ? 13 : 18,
                bottomTrailingRadius: phase == .collapsed ? 13 : 18,
                topTrailingRadius: 10
            )
            .strokeBorder(Color.white.opacity(phase == .collapsed ? 0.04 : 0.09), lineWidth: 1)
            .allowsHitTesting(false)
        }
        // The entire top row is solid black — including the physical notch
        // zone — but the center has no child content or actions.
        .contentShape(Rectangle())
        .onHover { hovering in
            if previewPhase == nil { coordinator.hover(hovering) }
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .animation(.easeOut(duration: 0.16), value: phase)
    }

    private var topBand: some View {
        Button {
            if phase == .expanded { openTerminalJobs() }
            else { coordinator.expand() }
        } label: {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .accessibilityHidden(true)
                    if phase != .collapsed {
                        Text("RelayOS")
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 12)
                .frame(width: layout.leftWidth)

                // Solid black and deliberately empty. No camera overlap.
                Color.black
                    .frame(width: layout.centerGap)
                    .accessibilityHidden(true)

                HStack(spacing: 7) {
                    Circle()
                        .fill(isRunning ? Color.green : Color.gray)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(primaryJob?.executableName ?? "No active build")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(primaryJob.map {
                                CommandJobProgress.elapsedLabel($0, at: context.date)
                            } ?? "Idle")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(muted)
                        }
                    }
                    Spacer(minLength: 0)
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
        .accessibilityLabel(isRunning
            ? "RelayOS, \(jobs.count) running jobs. Click to expand."
            : "RelayOS, no running builds. Click to expand.")
    }

    private var hoverStrip: some View {
        HStack(spacing: 7) {
            Image(systemName: isRunning ? "waveform.path" : "terminal")
                .foregroundStyle(isRunning ? Color.green : muted)
            Text(isRunning ? "\(jobs.count) job\(jobs.count == 1 ? "" : "s") running" : "No running builds")
                .lineLimit(1)
            Spacer()
            Text("Click to expand")
                .foregroundStyle(muted)
            Image(systemName: "chevron.down")
                .foregroundStyle(muted)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 15)
        .contentShape(Rectangle())
        .onTapGesture { coordinator.expand() }
    }

    private var expandedTray: some View {
        HStack(spacing: 10) {
            Image(systemName: isRunning ? "terminal.fill" : "checkmark.circle")
                .foregroundStyle(isRunning ? Color.green : muted)
                .font(.system(size: 16))

            Button(action: openTerminalJobs) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(isRunning
                         ? "\(jobs.count) active terminal job\(jobs.count == 1 ? "" : "s")"
                         : "No running builds")
                        .font(.system(size: 12, weight: .semibold))
                    Text(primaryJob.map {
                        URL(fileURLWithPath: $0.projectRoot).lastPathComponent
                            + " · " + $0.status.capitalized
                    } ?? "Open build history")
                    .font(.system(size: 10.5))
                    .foregroundStyle(muted)
                    .lineLimit(1)
                    if let job = primaryJob {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("Elapsed " + CommandJobProgress.elapsedLabel(job, at: context.date))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(muted)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if jobs.count > 1 {
                Text("+\(jobs.count - 1)")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.09), in: Capsule())
            }
            Button(action: openTerminalJobs) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open terminal jobs")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 30)
                    .foregroundStyle(muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide notch")
        }
        .padding(.horizontal, 17)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openTerminalJobs() {
        if let job = primaryJob { model.selectCommandJob(job.id) }
        if model.isSwiftOnly { model.showApprovalCenter() }
        else { model.showTerminalJobs() }
        onOpenMain()
        onClose()
    }
}

#if DEBUG
#Preview("Notch · Collapsed") {
    NotchPanelView(
        model: BridgeModel.preview(), coordinator: .shared,
        onClose: {}, onOpenMain: {},
        previewLayout: NotchPanelPlacement.layout(
            displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            hardwareNotchWidth: 190),
        previewPhase: .collapsed
    )
    .padding(24)
    .background(Color.gray.opacity(0.25))
}
#Preview("Notch · Hover") {
    NotchPanelView(
        model: BridgeModel.preview(), coordinator: .shared,
        onClose: {}, onOpenMain: {},
        previewLayout: NotchPanelPlacement.layout(
            displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            hardwareNotchWidth: 190, phase: .hovered),
        previewPhase: .hovered
    )
    .padding(24)
    .background(Color.gray.opacity(0.25))
}
#Preview("Notch · Expanded") {
    NotchPanelView(
        model: BridgeModel.preview(), coordinator: .shared,
        onClose: {}, onOpenMain: {},
        previewLayout: NotchPanelPlacement.layout(
            displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            hardwareNotchWidth: 190, phase: .expanded),
        previewPhase: .expanded
    )
    .padding(24)
    .background(Color.gray.opacity(0.25))
}
#endif
