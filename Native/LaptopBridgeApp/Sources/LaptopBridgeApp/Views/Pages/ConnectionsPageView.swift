import SwiftUI

struct ConnectionsPageView: View {
    @ObservedObject var model: BridgeModel
    @State private var copiedEndpoint = false

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
                    SettingsButton(
                        title: copiedEndpoint ? "Copied" : "Copy MCP endpoint",
                        icon: copiedEndpoint ? "checkmark" : "doc.on.doc",
                        style: .primary
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
        }
    }
}
