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
