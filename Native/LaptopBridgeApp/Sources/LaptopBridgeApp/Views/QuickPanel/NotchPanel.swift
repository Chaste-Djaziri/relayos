// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Views/QuickPanel/NotchPanel.swift
import SwiftUI
import AppKit

/// Places the panel at the top-center of the usable screen area. Its contents
/// never overlap the hardware notch or take over the macOS menu bar.
enum NotchPanelPlacement {
    static func frame(in visibleFrame: CGRect, preferredSize: CGSize = .init(width: 432, height: 392),
                      gap: CGFloat = 10) -> CGRect {
        let availableWidth = max(1, visibleFrame.width - 24)
        let availableHeight = max(1, visibleFrame.height - 24)
        let width = min(preferredSize.width, availableWidth)
        let height = min(preferredSize.height, availableHeight)
        return CGRect(
            x: visibleFrame.midX - width / 2,
            y: max(visibleFrame.minY + 12, visibleFrame.maxY - gap - height),
            width: width, height: height
        )
    }
}

private final class RelayOSNotchWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Only the local app can show and dismiss this panel. It does not activate
/// Accessibility, install global keyboard hooks, or inspect screen content.
@MainActor
final class NotchPanelCoordinator: ObservableObject {
    static let shared = NotchPanelCoordinator()

    @Published private(set) var isVisible = false
    private var panel: NSPanel?
    private var screenObserver: NSObjectProtocol?
    private var openMainWindow: (() -> Void)?
    private let preferredSize = CGSize(width: 432, height: 392)

    private init() {}

    func toggle(model: BridgeModel, openMainWindow: @escaping () -> Void) {
        if isVisible { dismiss() } else { present(model: model, openMainWindow: openMainWindow) }
    }

    func present(model: BridgeModel, openMainWindow: @escaping () -> Void) {
        self.openMainWindow = openMainWindow
        if let panel, panel.isVisible {
            reposition()
            panel.orderFrontRegardless()
            return
        }
        let rect = NotchPanelPlacement.frame(
            in: (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
                ?? CGRect(x: 0, y: 0, width: 1200, height: 800),
            preferredSize: preferredSize)
        let window = RelayOSNotchWindow(
            contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        window.isFloatingPanel = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = false
        window.contentView = NSHostingView(rootView:
            NotchPanelView(model: model,
                           onClose: { [weak self] in self?.dismiss() },
                           onOpenMain: { [weak self] in self?.openMainWindow?() })
                .frame(width: rect.width, height: rect.height)
        )
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

    func reposition() {
        guard let window = panel,
              let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = NotchPanelPlacement.frame(in: screen.visibleFrame, preferredSize: preferredSize)
        window.setFrame(frame, display: true, animate: false)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        openMainWindow = nil
        isVisible = false
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }
}

struct NotchPanelView: View {
    @ObservedObject var model: BridgeModel
    let onClose: () -> Void
    let onOpenMain: () -> Void
    @AppStorage(RelayOSTheme.modeKey) private var appearance = "system"
    @AppStorage(RelayOSTheme.accentKey) private var accent = "blue"

    private var accentColor: Color { RelayOSTheme.accent(accent) }
    private var localHealthy: Bool { model.mcpHealth == .healthy || model.running }
    private var pendingCount: Int { model.isSwiftOnly ? model.nativePendingCount : model.approvalInbox.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Capsule()
                    .fill(localHealthy ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text("RelayOS")
                    .font(.system(size: 13, weight: .semibold))
                Text(model.isSwiftOnly ? "SWIFT LOCAL" : "CONTROL CENTER")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close notch panel")
            }
            .padding(.horizontal, 18)
            .padding(.top, 17)
            .padding(.bottom, 14)

            HStack(spacing: 10) {
                notchStatus(title: "Local MCP",
                            text: localHealthy ? "Available" : "Unavailable",
                            icon: "desktopcomputer",
                            color: localHealthy ? .green : .orange)
                notchStatus(title: model.isSwiftOnly ? "Public tunnel" : "ngrok tunnel",
                            text: model.tunnelHealth == .healthy ? "Verified" : model.tunnelHealth.label,
                            icon: "network",
                            color: model.tunnelHealth == .healthy ? .green : .secondary)
            }
            .padding(.horizontal, 17)

            HStack {
                Image(systemName: "tray.full.fill")
                    .foregroundStyle(pendingCount == 0 ? .secondary : accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.isSwiftOnly ? "Native approvals" : "Approval inbox")
                        .font(.system(size: 12, weight: .semibold))
                    Text(model.isSwiftOnly
                         ? (pendingCount == 0 ? "No native requests waiting" : "\(pendingCount) native request(s) waiting")
                         : (pendingCount == 0 ? "No requests waiting"
                            : "\(pendingCount) request(s) waiting"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Review") { openSettings(approvals: true) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(12)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 17)
            .padding(.top, 12)

            if !model.isSwiftOnly {
                HStack(spacing: 10) {
                    Image(systemName: "terminal.fill")
                        .foregroundStyle(model.activeCommandJobsCount > 0 ? Color.green : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Terminal jobs")
                            .font(.system(size: 12, weight: .semibold))
                        Text(model.activeCommandJobsCount > 0
                             ? "\(model.activeCommandJobsCount) active · Live output available"
                             : "No running jobs")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Follow") {
                        if let active = model.commandJobs.first(where: \.active) {
                            model.selectCommandJob(active.id)
                        }
                        model.showTerminalJobs()
                        openSettings(approvals: false)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(12)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 17)
                .padding(.top, 10)
            }

            HStack(spacing: 8) {
                if !model.isSwiftOnly && !model.connectedClients.isEmpty {
                    Label("\(model.connectedClients.count) clients", systemImage: "person.2")
                } else {
                    Label(model.isSwiftOnly ? "Local development" : "No clients connected",
                          systemImage: "lock.shield")
                }
                Spacer(minLength: 4)
                if model.emergencyStop {
                    Label("Emergency stop", systemImage: "hand.raised.fill")
                        .foregroundStyle(.red)
                } else {
                    Label("Protected", systemImage: "checkmark.shield")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 15)

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button {
                    openSettings(approvals: false)
                } label: {
                    Label("Open RelayOS", systemImage: "square.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(accentColor)

                Button {
                    guard model.endpoint != "Not configured" else { return }
                    model.copyEndpoint()
                } label: {
                    Label("Copy MCP", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(model.endpoint == "Not configured")
            }
            .controlSize(.regular)
            .padding(.horizontal, 17)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 23))
        .overlay {
            RoundedRectangle(cornerRadius: 23)
                .strokeBorder(Color.primary.opacity(0.13), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 23))
        .preferredColorScheme(RelayOSTheme.scheme(appearance))
        .tint(accentColor)
    }

    private func notchStatus(title: String, text: String, icon: String,
                             color: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 24, height: 25)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(text).font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .padding(11)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }

    private func openSettings(approvals: Bool) {
        if approvals { model.showApprovalCenter() }
        onOpenMain()
        onClose()
    }
}

#if DEBUG
#Preview("Notch · Dark") {
    NotchPanelView(model: BridgeModel.preview(), onClose: {}, onOpenMain: {})
        .frame(width: 432, height: 392)
        .preferredColorScheme(.dark)
}
#Preview("Notch · Light") {
    NotchPanelView(model: BridgeModel.preview(), onClose: {}, onOpenMain: {})
        .frame(width: 432, height: 392)
        .preferredColorScheme(.light)
}
#endif
