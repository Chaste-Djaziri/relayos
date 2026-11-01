import SwiftUI
import AppKit

struct QuickPanel: View {
    @ObservedObject var model: BridgeModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "computermouse.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading) {
                    Text("RelayOS").font(.headline)
                    Text(model.running ? "MCP healthy" : "MCP offline or restarting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            LabeledContent("Public tunnel", value: model.tunnelHealth.label)
                .font(.caption)

            if !model.serviceNotice.isEmpty {
                Label(model.serviceNotice, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if model.endpoint == "Not configured" {
                GroupBox("First-run setup") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Create your public MCP endpoint with ngrok.").font(.subheadline)
                        HStack {
                            SecureField("ngrok authtoken", text: $model.ngrokToken)
                                .textFieldStyle(.roundedBorder)
                            Button("Paste token") {
                                if let value = NSPasteboard.general.string(forType: .string) {
                                    model.ngrokToken = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            }
                        }
                        TextField("Reserved domain (example.ngrok.app)", text: $model.ngrokDomainValue)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Install ngrok with Homebrew") { model.installNgrok() }
                            Button("Save and connect") { model.configureNgrok() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }

            GroupBox("Connections") {
                VStack(alignment: .leading, spacing: 10) {
                    if model.connectedClients.isEmpty {
                        Text("No connected AI clients").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(model.connectedClients.enumerated()), id: \.offset) { _, name in
                            ConnectionRow(name: name, connected: true)
                        }
                    }
                    Button("Copy MCP endpoint") { model.copyEndpoint() }
                }
            }

            if !model.approvalInbox.isEmpty {
                Button("Review \(model.approvalInbox.count) pending approvals") {
                    model.showApprovalCenter()
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.borderedProminent)
            }

            Text(model.endpoint)
                .font(.caption)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)

            Toggle("Emergency stop", isOn: Binding(
                get: { model.emergencyStop },
                set: { model.setEmergencyStop($0) }
            ))
            .toggleStyle(.sleekSwitch(tint: Color(red: 0.92, green: 0.26, blue: 0.26)))

            HStack {
                Button("Open RelayOS") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.bordered)

                Button("Settings") {
                    openWindow(id: "main")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Restart") { model.restartServices() }
                    .buttonStyle(.bordered)
                Button("Quit RelayOS") {
                    model.shutdownServices()
                    NSApp.terminate(nil)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
    }
}
