// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Views/QuickPanel/QuickPanel.swift
import SwiftUI
import AppKit

/// Compact control center opened by the macOS menu-bar icon. It never owns the
/// MCP lifecycle; Python-backed capabilities stay available in normal mode.
struct QuickPanel: View {
    @ObservedObject var model: BridgeModel
    @ObservedObject private var notch = NotchPanelCoordinator.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage(RelayOSTheme.accentKey) private var accent = "blue"
    @State private var confirmEmergencyStop = false
    @State private var confirmRestart = false

    private var palette: ThemeColors { RelayOSTheme.colors(colorScheme) }
    private var accentColor: Color { RelayOSTheme.accent(accent) }
    private var isOnline: Bool { model.mcpHealth == .healthy || model.running }
    private var canManageServices: Bool { !model.isPreview && !model.isDevelopmentClient }
    private var pendingCount: Int { model.isSwiftOnly ? model.nativePendingCount : model.approvalInbox.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 40, height: 40)
                    .background(accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("RelayOS")
                        .font(.system(size: 17, weight: .bold))
                    Text(model.isSwiftOnly ? "Swift-only local development"
                         : model.isDevelopmentClient ? "Development · observing live agent"
                         : "Mac control center")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Circle()
                    .fill(isOnline ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                    .accessibilityLabel(isOnline ? "Local service available" : "Local service unavailable")
            }
            .padding(.bottom, 17)

            HStack(spacing: 9) {
                statusTile("Local MCP", systemImage: "desktopcomputer",
                           status: isOnline ? "Healthy" : "Unavailable",
                           tint: isOnline ? .green : .orange)
                statusTile("Public MCP", systemImage: "network",
                           status: model.tunnelHealth == .healthy ? "Verified" :
                               (model.isSwiftOnly ? "Local only" : model.tunnelHealth.label),
                           tint: model.tunnelHealth == .healthy ? .green : .secondary)
            }
            .padding(.bottom, 13)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Approvals", systemImage: "tray.full")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if pendingCount > 0 {
                        Text("\(pendingCount)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(accentColor, in: Capsule())
                    } else {
                        Text(model.isSwiftOnly ? "Native inbox" : "Up to date")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                if let first = model.approvalInbox.first, !model.isSwiftOnly {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(first.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text(first.target)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(model.isSwiftOnly
                         ? (pendingCount == 0 ? "No pending native requests." : "\(pendingCount) native request(s) waiting.")
                         : "No pending authorization requests.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Button {
                    openSettings(approvals: true)
                } label: {
                    HStack {
                        Text("Review inbox")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(accentColor)
            }
            .padding(14)
            .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13)
                .strokeBorder(palette.cardBorder, lineWidth: 1))
            .padding(.bottom, 12)

            if !model.connectedClients.isEmpty && !model.isSwiftOnly {
                HStack(spacing: 7) {
                    Image(systemName: "person.2")
                    Text("\(model.connectedClients.count) connected client(s)")
                    Spacer(minLength: 4)
                    Text(model.connectedClients.prefix(2).joined(separator: ", "))
                        .lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)
            }

            if !model.serviceNotice.isEmpty {
                Label(model.serviceNotice, systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
            }

            HStack(spacing: 9) {
                Button {
                    openSettings(approvals: false)
                } label: {
                    Label("Open RelayOS", systemImage: "square.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(accentColor)

                Button {
                    notch.toggle(model: model) {
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                } label: {
                    Label(notch.isVisible ? "Hide notch" : "Show notch",
                          systemImage: "rectangle.topthird.inset.filled")
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.regular)
            .padding(.bottom, 10)

            HStack(spacing: 8) {
                Button {
                    model.copyEndpoint()
                } label: {
                    Label("Copy endpoint", systemImage: "doc.on.doc")
                }
                .disabled(model.endpoint == "Not configured")
                .buttonStyle(.plain)

                Spacer()

                if canManageServices {
                    Button("Restart services") { confirmRestart = true }
                        .buttonStyle(.plain)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Rectangle()
                .fill(palette.cardDivider)
                .frame(height: 1)
                .padding(.vertical, 13)

            HStack(spacing: 10) {
                Button {
                    confirmEmergencyStop = true
                } label: {
                    Label(model.emergencyStop ? "Emergency stop active" : "Emergency stop",
                          systemImage: "hand.raised")
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.emergencyStop ? .red : .secondary)
                .disabled(!canManageServices || model.emergencyStopInFlight)
                Spacer()
                Button("Quit") {
                    notch.dismiss()
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
        }
        .padding(17)
        .frame(width: 384)
        .background(palette.windowBackground)
        .alert(model.emergencyStop ? "Resume RelayOS access?" : "Stop all RelayOS access?",
               isPresented: $confirmEmergencyStop) {
            Button("Cancel", role: .cancel) {}
            Button(model.emergencyStop ? "Resume access" : "Emergency stop",
                   role: .destructive) {
                guard canManageServices else { return }
                model.setEmergencyStop(!model.emergencyStop)
            }
        } message: {
            Text("This changes live authorization state and may terminate active sessions.")
        }
        .confirmationDialog("Restart RelayOS services?", isPresented: $confirmRestart) {
            Button("Restart services") {
                guard canManageServices else { return }
                model.restartServices()
            }
        } message: {
            Text("The local MCP service and its tunnel may briefly disconnect.")
        }
    }

    private func statusTile(_ title: String, systemImage: String,
                            status: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(status)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(palette.cardBorder, lineWidth: 1))
    }

    private func openSettings(approvals: Bool) {
        if approvals { model.showApprovalCenter() }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

#if DEBUG
#Preview("Menu bar · Connected") {
    QuickPanel(model: BridgeModel.preview())
        .frame(width: 384)
}
#Preview("Menu bar · Disconnected") {
    let model = BridgeModel(preview: true)
    QuickPanel(model: model)
        .frame(width: 384)
}
#endif
