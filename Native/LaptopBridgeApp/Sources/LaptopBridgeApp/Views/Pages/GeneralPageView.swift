import SwiftUI

struct GeneralPageView: View {
    @ObservedObject var model: BridgeModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ApprovalSound.preferenceKey) private var approvalSoundsEnabled = true
    @AppStorage(ApprovalArrivalNotification.enabledKey) private var approvalNotificationsEnabled = false
    @State private var copiedEndpoint = false

    private var theme: ThemeColors {
        RelayOSTheme.colors(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "Connections") {
                SettingsCardRow(
                    title: "MCP endpoint",
                    subtitle: "Public HTTPS URL for AI clients to connect to this machine"
                ) {
                    HStack(spacing: 8) {
                        Text(model.endpoint)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        SettingsButton(
                            title: copiedEndpoint ? "Copied" : "Copy",
                            icon: copiedEndpoint ? "checkmark" : "doc.on.doc",
                            style: copiedEndpoint ? .primary : .secondary
                        ) {
                            model.copyEndpoint()
                            withAnimation(.easeInOut(duration: 0.15)) {
                                copiedEndpoint = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    copiedEndpoint = false
                                }
                            }
                        }
                    }
                }

                SettingsCardRow(
                    title: "Local MCP",
                    subtitle: "FastAPI server running locally on localhost"
                ) {
                    StatusBadge(
                        text: model.mcpHealth.rawValue.capitalized,
                        status: model.mcpHealth == .healthy ? .healthy : (model.mcpHealth == .unreachable ? .offline : .warning)
                    )
                }

                SettingsCardRow(
                    title: "Public MCP",
                    subtitle: "ngrok verified public HTTPS connectivity"
                ) {
                    StatusBadge(
                        text: model.tunnelHealth.label,
                        status: model.tunnelHealth == .healthy ? .healthy : (model.tunnelHealth == .connecting ? .warning : .offline)
                    )
                }

                if !model.serviceNotice.isEmpty {
                    SettingsCardRow(
                        title: "Service notice",
                        subtitle: model.serviceNotice
                    ) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                SettingsCardRow(
                    title: "Services control",
                    subtitle: "Restart local backend and refresh ngrok tunnel session",
                    showDivider: false
                ) {
                    SettingsButton(title: "Restart services", icon: "arrow.clockwise", style: .secondary) {
                        model.restartServices()
                    }
                }
            }

            SettingsCard(title: "Permissions & Safety") {
                SettingsCardRow(
                    title: "Emergency stop",
                    subtitle: "Immediately blocks active sessions, cancels terminal jobs, and revokes OAuth tokens. Enforced at SQLite authorization boundary.",
                    showDivider: false
                ) {
                    SettingsToggle(
                        isOn: Binding(
                            get: { model.emergencyStop },
                            set: { model.setEmergencyStop($0) }
                        ),
                        tintColor: Color(red: 0.92, green: 0.26, blue: 0.26)
                    )
                }
            }

            SettingsCard(title: "Approval notifications") {
                SettingsCardRow(
                    title: "Sound alerts",
                    subtitle: "Play sound effect when a new tool approval request arrives"
                ) {
                    SettingsToggle(isOn: $approvalSoundsEnabled)
                }

                SettingsCardRow(
                    title: "macOS notifications",
                    subtitle: "Display notification banner on arrival. Alerts are sent once per newly discovered request; command arguments are excluded.",
                    showDivider: false
                ) {
                    SettingsToggle(isOn: $approvalNotificationsEnabled)
                        .onChange(of: approvalNotificationsEnabled) { _, enabled in
                            if enabled { ApprovalArrivalNotification.requestPermission() }
                        }
                }
            }
        }
    }
}
