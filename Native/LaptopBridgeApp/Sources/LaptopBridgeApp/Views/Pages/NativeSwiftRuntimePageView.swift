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
    @State private var pending: [NativeMCPApprovalStore.Request] = []
    @State private var audit: [[String: String]] = []
    private var inbox: NativeMCPApprovalStore {
        NativeMCPApprovalStore(databaseURL: store.databaseURL)
    }

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
            SettingsCard(title: "Native approval inbox") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Pending file and terminal requests")
                            .foregroundStyle(.secondary)
                        Spacer()
                        SettingsButton(title: "Refresh", icon: "arrow.clockwise") {
                            refreshRequests()
                        }
                    }
                    if pending.isEmpty {
                        Text("No pending requests").foregroundStyle(.secondary)
                    }
                    ForEach(pending, id: \.id) { request in
                        VStack(alignment: .leading, spacing: 9) {
                            Text(request.kind).font(.subheadline.bold())
                            Text(request.target)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                SettingsButton(title: "Approve once", icon: "checkmark") {
                                    decide(request, .once)
                                }
                                SettingsButton(title: "Deny", icon: "xmark",
                                               style: .destructive) {
                                    decide(request, .deny)
                                }
                            }
                        }
                        .padding(10)
                        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    Text("Only this local window can approve. Every approval is single-use and bound to the exact requested operation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
            SettingsCard(title: "Native approval activity") {
                VStack(alignment: .leading, spacing: 8) {
                    if audit.isEmpty {
                        Text("No local approval history yet").foregroundStyle(.secondary)
                    }
                    ForEach(audit.indices, id: \.self) { index in
                        let event = audit[index]
                        HStack {
                            Text(event["event"] ?? "Unknown")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text(String((event["request_id"] ?? "").prefix(12)))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
            }
            SettingsCard(title: "Screen guidance") {
                SettingsCardRow(title: "Clear overlay",
                                subtitle: "Dismiss any on-screen guidance immediately.",
                                showDivider: false) {
                    SettingsButton(title: "Clear now", icon: "xmark.circle") {
                        NativeGuidanceSessions.shared.stopAll()
                    }
                }
            }
            Text("Swift-only local development supports OAuth, approval-gated writes and commands, command jobs and optional screen guidance. Public MCP transport compatibility and release security validation are still pending.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { refreshRequests() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            refreshRequests()
        }
    }

    private func refreshRequests() {
        guard model.isSwiftOnly else { return }
        do {
            pending = try inbox.pending()
            audit = try inbox.activity(limit: 15)
        }
        catch { message = "Unable to read local approvals: \(error.localizedDescription)" }
    }

    private func decide(_ request: NativeMCPApprovalStore.Request,
                        _ decision: NativeMCPApprovalStore.Decision) {
        guard model.isSwiftOnly else { return }
        do {
            try inbox.decide(id: request.id, decision: decision)
            message = decision == .deny ? "Request denied." : "Exact request approved once."
        } catch {
            message = "Approval decision failed: \(error.localizedDescription)"
        }
        refreshRequests()
    }
}

#if DEBUG
#Preview("Swift-only local development") {
    PreviewPageFrame("Native Swift MCP") {
        NativeSwiftRuntimePageView(model: BridgeModel.preview())
    }
}
#endif
