import SwiftUI
import AppKit

struct FreshSetupView: View {
    @ObservedObject var model: BridgeModel
    @State private var tokenInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "computermouse.fill")
                .font(.system(size: 56))
                .foregroundStyle(.blue)
                .frame(width: 72, height: 72)
            Text("Set up RelayOS").font(.largeTitle.bold())
            Text("Create a private HTTPS MCP endpoint for ChatGPT, Claude, Gemini, and other MCP clients.")
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Link("Get authtoken", destination: URL(string: "https://dashboard.ngrok.com/get-started/your-authtoken")!)
            }
            .font(.callout)

            Text("1. Install ngrok. 2. Sign in to ngrok and copy your authtoken. ngrok assigns a free stable dev domain automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Form {
                Section("ngrok connection") {
                    HStack {
                        SecureField("ngrok authtoken", text: $tokenInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(minHeight: 30)
                        Button("Paste token") {
                            if let value = NSPasteboard.general.string(forType: .string) {
                                tokenInput = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                    }
                    Text("Your free ngrok dev domain will appear automatically after connection. The token is stored locally.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if model.ngrokInstallState == "Installing ngrok…" {
                        ProgressView("Installing ngrok…")
                    } else if !model.ngrokInstallState.isEmpty {
                        Text(model.ngrokInstallState)
                            .font(.caption)
                            .foregroundStyle(model.ngrokInstallState.contains("successfully") || model.ngrokInstallState.contains("already") ? .green : .red)
                    }
                }

                Section {
                    HStack {
                        Button("Install ngrok with Homebrew") { model.installNgrok() }
                        Spacer()
                        Button("Save and connect") {
                            model.ngrokToken = tokenInput
                            model.ngrokDomainValue = ""
                            model.configureNgrok()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .formStyle(.grouped)

            Spacer()
        }
        .padding(36)
    }
}
