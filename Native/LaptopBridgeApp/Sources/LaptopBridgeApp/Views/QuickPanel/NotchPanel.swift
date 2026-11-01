// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Views/QuickPanel/NotchPanel.swift
import AppKit
import SwiftUI

/// The camera housing is a *real* screen exclusion, never a drawn widget.
/// Only the ears to either side and the tray immediately below it are opaque.
enum NotchPanelPlacement {
    struct Layout {
        let frame: CGRect
        let topBandHeight: CGFloat
        let centerGap: CGFloat
        let leftWidth: CGFloat
        let rightWidth: CGFloat
        let hasHardwareNotch: Bool
    }

    static let preferredWidth: CGFloat = 568
    static let trayHeight: CGFloat = 74

    static func layout(displayFrame: CGRect, visibleFrame: CGRect,
                       hardwareNotchWidth: CGFloat? = nil) -> Layout {
        let menuBand = max(0, displayFrame.maxY - visibleFrame.maxY)
        let hasNotch = (hardwareNotchWidth ?? 0) > 60 && menuBand > 15
        let width = max(1, min(preferredWidth, visibleFrame.width - 24))
        let topHeight = hasNotch ? min(max(30, menuBand), 42) : 36
        let gap = min(max((hardwareNotchWidth ?? 190) + 24, 205), max(1, width - 155))
        let availableSides = max(0, width - gap)
        let leftWidth = min(145, availableSides * 0.43)
        let rightWidth = availableSides - leftWidth
        let height = topHeight + trayHeight
        let topEdge = hasNotch ? displayFrame.maxY : visibleFrame.maxY - 8
        let frame = CGRect(x: visibleFrame.midX - width / 2,
                           y: max(visibleFrame.minY + 8, topEdge - height),
                           width: width, height: height)
        return Layout(frame: frame, topBandHeight: topHeight,
                      centerGap: gap, leftWidth: leftWidth, rightWidth: rightWidth,
                      hasHardwareNotch: hasNotch)
    }

    /// NSScreen reports the usable menu-bar regions on either side of a notch.
    /// Fall back to the below-menu-bar design when those regions are unavailable.
    static func layout(for screen: NSScreen) -> Layout {
        let gap: CGFloat?
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           left.width > 0, right.width > 0, right.minX > left.maxX {
            gap = right.minX - left.maxX
        } else {
            gap = nil
        }
        return layout(displayFrame: screen.frame, visibleFrame: screen.visibleFrame,
                      hardwareNotchWidth: gap)
    }

    // Retain a simple geometry adapter for integrations using the older API.
    static func frame(in visibleFrame: CGRect,
                      preferredSize: CGSize = .init(width: preferredWidth,
                                                    height: trayHeight + 36),
                      gap: CGFloat = 10) -> CGRect {
        let width = min(preferredSize.width, max(1, visibleFrame.width - 24))
        let height = min(preferredSize.height, max(1, visibleFrame.height - 24))
        return CGRect(x: visibleFrame.midX - width / 2,
                      y: visibleFrame.maxY - gap - height,
                      width: width, height: height)
    }
}

private final class RelayOSNotchWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) {
        NotchPanelCoordinator.shared.dismiss()
    }
}

/// Owns a single optional, local-only AppKit panel. Does not start a server,
/// install an event tap, capture a screen, or read terminal output itself.
@MainActor
final class NotchPanelCoordinator: ObservableObject {
    static let shared = NotchPanelCoordinator()

    @Published private(set) var isVisible = false
    private var panel: NSPanel?
    private var model: BridgeModel?
    private var screenObserver: NSObjectProtocol?
    private var openMainWindow: (() -> Void)?

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
        let layout = NotchPanelPlacement.layout(for: screen)
        let window = RelayOSNotchWindow(contentRect: layout.frame,
                                         styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
        window.isFloatingPanel = true
        // The ears share the menu-bar band; the center gap remains clear.
        window.level = layout.hasHardwareNotch ? .statusBar : .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = false
        window.contentView = hostingView(model: model, layout: layout)
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

    private func hostingView(model: BridgeModel,
                             layout: NotchPanelPlacement.Layout) -> NSView {
        NSHostingView(rootView:
            NotchPanelView(model: model, layout: layout,
                           onClose: { [weak self] in self?.dismiss() },
                           onOpenMain: { [weak self] in self?.openMainWindow?() })
                .frame(width: layout.frame.width, height: layout.frame.height)
        )
    }

    func reposition() {
        guard let panel, let model,
              let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        let layout = NotchPanelPlacement.layout(for: screen)
        panel.level = layout.hasHardwareNotch ? .statusBar : .floating
        panel.setFrame(layout.frame, display: true, animate: false)
        panel.contentView = hostingView(model: model, layout: layout)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        model = nil
        openMainWindow = nil
        isVisible = false
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }
}

/// Only the two side ears occupy the camera's vertical band. The central
/// transparent gap receives no SwiftUI content, including in Xcode previews.
struct NotchPanelView: View {
    @ObservedObject var model: BridgeModel
    let layout: NotchPanelPlacement.Layout
    let onClose: () -> Void
    let onOpenMain: () -> Void

    private let chrome = Color.black
    private let secondaryText = Color.white.opacity(0.58)

    private var activeJobs: [CommandJobEntry] {
        model.commandJobs.filter(\.active).sorted {
            if $0.status != $1.status { return $0.status == "running" }
            return $0.createdAt > $1.createdAt
        }
    }
    private var primaryJob: CommandJobEntry? { activeJobs.first }
    private var activeCount: Int { activeJobs.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                logoEar
                    .frame(width: layout.leftWidth, height: layout.topBandHeight)
                // Intentionally transparent: this area is occupied by the
                // physical camera housing on a notched MacBook.
                Color.clear
                    .frame(width: layout.centerGap, height: layout.topBandHeight)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                buildEar
                    .frame(width: layout.rightWidth, height: layout.topBandHeight)
            }
            .frame(height: layout.topBandHeight)

            buildTray
                .frame(height: NotchPanelPlacement.trayHeight)
        }
        .frame(width: layout.frame.width, height: layout.frame.height)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
    }

    private var logoEar: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 21, height: 21)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .accessibilityHidden(true)
            Text("RelayOS")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .background(chrome)
        .clipShape(.rect(topLeadingRadius: 10))
        .accessibilityLabel("RelayOS notch companion")
    }

    private var buildEar: some View {
        Button(action: openTerminalJobs) {
            HStack(spacing: 7) {
                Circle()
                    .fill(activeCount > 0 ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(primaryJob?.executableName ?? "No active build")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(primaryJob.map {
                            CommandJobProgress.elapsedLabel($0, at: context.date)
                        } ?? "Idle")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(secondaryText)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.leading, 11)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(chrome)
            .clipShape(.rect(topTrailingRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(primaryJob.map {
            "\($0.executableName), \(CommandJobProgress.elapsedLabel($0)) elapsed. Open terminal jobs."
        } ?? "No active terminal builds. Open history.")
    }

    private var buildTray: some View {
        HStack(spacing: 11) {
            Image(systemName: activeCount > 0 ? "terminal.fill" : "checkmark.circle")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(activeCount > 0 ? Color.green : secondaryText)
                .frame(width: 22)
                .accessibilityHidden(true)

            Button(action: openTerminalJobs) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(activeCount == 0
                         ? "No running builds"
                         : "\(activeCount) active terminal job\(activeCount == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(primaryJob.map {
                        URL(fileURLWithPath: $0.projectRoot).lastPathComponent + "  ·  " + $0.status.capitalized
                    } ?? "Click to view your build history")
                    .font(.system(size: 10.5))
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if activeCount > 1 {
                Text("+\(activeCount - 1)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.1), in: Capsule())
                    .accessibilityLabel("\(activeCount - 1) additional active jobs")
            }

            Button(action: openTerminalJobs) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.09), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open terminal jobs")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(secondaryText)
                    .frame(width: 24, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide notch companion")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(chrome)
        .clipShape(.rect(bottomLeadingRadius: 18, bottomTrailingRadius: 18))
        .overlay(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.075), lineWidth: 1)
                .frame(height: 74)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private func openTerminalJobs() {
        if let job = primaryJob { model.selectCommandJob(job.id) }
        if model.isSwiftOnly {
            model.showApprovalCenter() // Native dev currently has no hybrid job monitor.
        } else {
            model.showTerminalJobs()
        }
        onOpenMain()
        onClose()
    }
}

#if DEBUG
#Preview("Notch · Running build") {
    NotchPanelView(
        model: BridgeModel.preview(),
        layout: NotchPanelPlacement.layout(
            displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            hardwareNotchWidth: 190
        ),
        onClose: {}, onOpenMain: {}
    )
    .frame(width: 568, height: 112)
    .padding(24)
    .background(Color.gray.opacity(0.25))
}
#Preview("Notch · No camera housing") {
    NotchPanelView(
        model: BridgeModel(preview: true),
        layout: NotchPanelPlacement.layout(
            displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
        ),
        onClose: {}, onOpenMain: {}
    )
    .frame(width: 568, height: 110)
    .padding(24)
    .background(Color.gray.opacity(0.25))
}
#endif
