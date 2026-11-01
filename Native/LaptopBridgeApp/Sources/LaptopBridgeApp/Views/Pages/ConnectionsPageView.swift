import SwiftUI

struct ConnectionsPageView: View {
    @ObservedObject var model: BridgeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "Connected AI clients") {
                if model.connectedClients.isEmpty {
                    SettingsCardRow(
                        title: "No connected AI clients",
                        subtitle: "Add RelayOS's MCP endpoint URL to ChatGPT, Claude, or other MCP clients to start pair programming."
                    ) {
                        StatusBadge(text: "Waiting", status: .neutral)
                    }
                } else {
                    ForEach(Array(model.connectedClients.enumerated()), id: \.offset) { _, name in
                        SettingsCardRow(
                            title: name,
                            subtitle: "Authenticated MCP client session"
                        ) {
                            StatusBadge(text: "Connected", status: .healthy)
                        }
                    }
                }

                SettingsCardRow(
                    title: "MCP endpoint URL",
                    subtitle: "The public HTTPS URL configured for client connections",
                    showDivider: false
                ) {
                    SettingsButton(title: "Copy MCP endpoint", icon: "doc.on.doc", style: .primary) {
                        model.copyEndpoint()
                    }
                }
            }
        }
    }
}
