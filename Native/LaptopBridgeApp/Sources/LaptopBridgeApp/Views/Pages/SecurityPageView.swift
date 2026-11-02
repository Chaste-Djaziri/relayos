import SwiftUI

struct SecurityPageView: View {
    @ObservedObject var model: BridgeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "Emergency controls") {
                SettingsCardRow(
                    title: "Emergency stop",
                    subtitle: "Blocks all command execution, revokes active OAuth tokens, and refuses incoming MCP tool calls. Persisted directly in RelayOS SQLite database.",
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

            SettingsCard(title: "Screen sharing · optional") {
                SettingsCardRow(
                    title: "Main-display sharing session",
                    subtitle: model.screenSharingActive
                        ? "Active for \(model.screenSharingSecondsRemaining / 60 + 1) minutes at most. Every screenshot remains a separate, logged capture. Press Stop to revoke."
                        : "Start from this Mac to allow main-display captures for 30 minutes without individual approval prompts. Never enables itself."
                ) {
                    Button(model.screenSharingActive ? "Stop sharing" : "Share for 30 min") {
                        model.setScreenSharing(!model.screenSharingActive)
                    }
                    .disabled(model.screenSharingBusy || model.isDevelopmentClient ||
                              model.isPreview || (!model.screenSharingActive &&
                              (!model.screenGuidance || model.emergencyStop)))
                }
                if let error = model.screenSharingError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(10)
                }
                SettingsCardRow(
                    title: "Scope and protections",
                    subtitle: "Only the main display. Named windows and apps still require Approve Once. Session ends automatically, on Stop, on server restart, or on Emergency Stop.",
                    showDivider: false
                ) {
                    StatusBadge(text: model.screenSharingActive ? "Sharing" : "Off",
                                status: model.screenSharingActive ? .healthy : .offline)
                }
            }

            SettingsCard(title: "Authorization boundary") {
                SettingsCardRow(
                    title: "Independent local approval",
                    subtitle: "Project sessions and terminal commands require local approval on this Mac. AI client approval tool calls are never accepted without verified local consent."
                ) {
                    StatusBadge(text: "Enforced locally", status: .healthy)
                }

                SettingsCardRow(
                    title: "Database audit trail",
                    subtitle: "All approval decisions, denials, executions, and revoked permissions are recorded in RelayOS local audit tables.",
                    showDivider: false
                ) {
                    StatusBadge(text: "Active", status: .healthy)
                }
            }
        }
    }
}

#if DEBUG
#Preview("Security") {
    let model = BridgeModel.preview()
    PreviewPageFrame("Security") {
        SecurityPageView(model: model)
    }
}
#endif
