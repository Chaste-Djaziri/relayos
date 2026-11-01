// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Views/Pages/SystemPermissionsPageView.swift
import SwiftUI
import AppKit

struct SystemPermissionsPageView: View {
    @ObservedObject var model: BridgeModel
    @StateObject private var permissions = SystemPermissionAccess()
    @Environment(\.colorScheme) private var scheme
    @AppStorage(RelayOSTheme.fontSizeKey) private var fontSize = 14.0

    private var theme: ThemeColors { RelayOSTheme.colors(scheme) }
    private var scale: CGFloat { RelayOSTheme.scale(fontSize) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("macOS permissions are independent of RelayOS project approvals.")
                        .font(.system(size: 13 * scale))
                        .foregroundStyle(theme.textPrimary)
                    Text("Only enable features you need. RelayOS cannot grant itself permission. macOS may require an app restart after a change.")
                        .font(.system(size: 11.5 * scale))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                SettingsButton(title: "Check again", icon: "arrow.clockwise") {
                    permissions.refresh()
                }
            }

            SettingsCard(title: "Core permissions") {
                permissionRow(.screenRecording)
                permissionRow(.accessibility)
                permissionRow(.notifications, last: true)
            }
            SettingsCard(title: "Optional extended access") {
                permissionRow(.fullDiskAccess)
                permissionRow(.automation)
                permissionRow(.appManagement)
                permissionRow(.filesAndFolders, last: true)
            }
            Text("Full Disk Access, Automation, App Management, and Files & Folders have no reliable global status API. Review them in System Settings instead of relying on a misleading green badge. Only the running signed RelayOS.app can be selected for permission grants.")
                .font(.system(size: 11 * scale))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    private func permissionRow(_ kind: SystemPermissionKind, last: Bool = false) -> some View {
        let observation = permissions.observation(for: kind)
        return SettingsCardRow(
            title: kind.title,
            subtitle: kind.explanation,
            showDivider: !last
        ) {
            HStack(spacing: 10) {
                StatusBadge(
                    text: observation.label,
                    status: observation == .granted ? .healthy :
                        observation == .notGranted ? .warning : .neutral
                )
                SettingsButton(
                    title: "Open Settings",
                    icon: "arrow.up.right.square",
                    style: .secondary
                ) {
                    permissions.openGuide(for: kind)
                }
            }
        }
    }
}
