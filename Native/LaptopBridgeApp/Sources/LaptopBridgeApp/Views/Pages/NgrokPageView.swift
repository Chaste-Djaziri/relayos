import SwiftUI

struct NgrokPageView: View {
    @ObservedObject var model: BridgeModel
    @State private var copiedEndpoint = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "ngrok transport") {
                SettingsCardRow(
                    title: "Tunnel process",
                    subtitle: "Local ngrok daemon process status"
                ) {
                    StatusBadge(
                        text: model.tunnelRunning ? "Running" : "Stopped",
                        status: model.tunnelRunning ? .healthy : .offline
                    )
                }

                SettingsCardRow(
                    title: "Public health",
                    subtitle: "Public tunnel health verified via unauthenticated HTTP 401 check"
                ) {
                    StatusBadge(
                        text: model.tunnelHealth.label,
                        status: model.tunnelHealth == .healthy ? .healthy : (model.tunnelHealth == .connecting ? .warning : .offline)
                    )
                }

                SettingsCardRow(
                    title: "Configured endpoint",
                    subtitle: model.endpoint
                ) {
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

                SettingsCardRow(
                    title: "Session reconnect",
                    subtitle: "A running ngrok process alone does not prove connectivity. Click reconnect to cycle tunnel processes.",
                    showDivider: false
                ) {
                    SettingsButton(title: "Reconnect", icon: "arrow.clockwise", style: .secondary) {
                        model.restartServices()
                    }
                }
            }
        }
    }
}
