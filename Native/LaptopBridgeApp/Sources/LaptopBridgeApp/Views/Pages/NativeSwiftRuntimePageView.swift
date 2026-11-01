// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Views/Pages/NativeSwiftRuntimePageView.swift
import SwiftUI
import AppKit

/// Only shown when Xcode uses RELAYOS_SWIFT_ONLY=1.
/// Every authorization action here requires a local click or NSOpenPanel.
struct NativeSwiftRuntimePageView: View {
    @ObservedObject var model: BridgeModel
    @State private var lastSession: String?
    @State private var lastFolder: String?
    @State private var message: String?

    private let store = NativeMCPDevelopmentStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "Swift-only local MCP") {
                SettingsCardRow(title: "Runtime", subtitle: "Native Network.framework listener inside RelayOS.app") {
                    StatusBadge(text: model.mcpHealth == .healthy ? "Listening" : "Unavailable",
                                status: model.mcpHealth == .healthy ? .healthy : .offline)
                }
                SettingsCardRow(title: "Endpoint", subtitle: store.endpoint) {
                    SettingsButton(title: "Copy", icon: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(store.endpoint, forType: .string)
                    }
                }
                SettingsCardRow(title: "Local test bearer token", subtitle: "Stored in a user-only file. Never use it with the public ngrok tunnel.") {
                    SettingsButton(title: "Copy test token", icon: "doc.on.doc") {
                        guard let token = try? String(contentsOf: store.credentialURL, encoding: .utf8) else {
                            message = "Local test token does not exist; relaunch the Debug app."
                            return
                        }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(token, forType: .string)
                        message = "Development token copied. Do not share it or add it to Git."
                    }
                }
                SettingsCardRow(title: "Development state", subtitle: store.directory.path, showDivider: false) {
                    SettingsButton(title: "Reveal", icon: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.directory])
                    }
                }
            }

            SettingsCard(title: "Locally approved project sessions") {
                SettingsCardRow(
                    title: "Grant a temporary project folder",
                    subtitle: "Choose a directory using macOS Open. The permission expires within one hour.",
                    showDivider: lastSession == nil
                ) {
                    SettingsButton(title: "Choose folder", icon: "folder.badge.plus", style: .primary) {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.prompt = "Approve folder for Swift MCP"
                        guard panel.runModal() == .OK, let url = panel.url else { return }
                        do {
                            lastSession = try store.grantProjectFolder(url)
                            lastFolder = url.path
                            message = "Approved a local 60-minute project session."
                        } catch {
                            message = "Failed to grant folder: \(error.localizedDescription)"
                        }
                    }
                }
                if let session = lastSession {
                    SettingsCardRow(title: lastFolder ?? "Project folder",
                                    subtitle: "Session ID: \(session.prefix(18))…", showDivider: false) {
                        HStack {
                            SettingsButton(title: "Copy session ID", icon: "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(session, forType: .string)
                            }
                            SettingsButton(title: "Revoke", icon: "xmark", style: .destructive) {
                                do {
                                    try store.revokeSession(session)
                                    lastSession = nil
                                    lastFolder = nil
                                    message = "Native session revoked."
                                } catch {
                                    message = "Could not revoke: \(error.localizedDescription)"
                                }
                            }
                        }
                    }
                }
            }
            Text("This is not yet a production-compatible MCP server. OAuth client registration, terminal jobs, mutations, approvals and screen guidance are intentionally unavailable until they pass security parity tests.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

#if DEBUG
#Preview("Swift-only local development") {
    PreviewPageFrame("Native Swift MCP") {
        NativeSwiftRuntimePageView(model: BridgeModel.preview())
    }
}
#endif
