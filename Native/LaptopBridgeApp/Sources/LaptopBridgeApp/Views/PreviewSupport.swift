// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Views/PreviewSupport.swift
import SwiftUI

// Reusable preview *data and framing*, not a separate preview screen.
// Each actual view declares its own #Preview beside its implementation.
#if DEBUG
@MainActor
extension BridgeModel {
    static func preview() -> BridgeModel {
        let model = BridgeModel(preview: true)
        model.endpoint = "https://relayos-example.ngrok-free.dev/mcp"
        model.running = true
        model.mcpHealth = .healthy
        model.tunnelHealth = .healthy
        model.tunnelRunning = true
        model.projectTools = true
        model.connectedClients = ["ChatGPT", "Claude"]
        model.permissionGrants = [
            ["folder": "/Users/demo/Projects/RelayOS", "token": "demo-folder-token"]
        ]
        let now = Date().timeIntervalSince1970
        model.approvalInbox = [
            ApprovalInboxItem(
                requestID: "preview-command", kind: "project_command",
                target: "git status", argv: ["git", "status"],
                context: .init(
                    cwd: "/Users/demo/Projects/RelayOS",
                    requestedGrant: "once", commandFamily: nil,
                    scopePrefix: nil, clientID: nil, sessionID: "sample-session"),
                createdAt: now - 30, expiresAt: now + 1800
            )
        ]
        model.approvalActivity = [
            ApprovalActivityEntry(
                id: 41, recordedAt: now - 240, kind: "project_command",
                target: "/Users/demo/Projects/RelayOS:git status",
                decision: "executed", exitCode: 0, durationMS: 124,
                detailJSON: #"{"command":"git status","working_directory":"/Users/demo/Projects/RelayOS"}"#
            ),
            ApprovalActivityEntry(
                id: 40, recordedAt: now - 780, kind: "oauth_connection",
                target: "ChatGPT", decision: "approved",
                exitCode: nil, durationMS: nil, detailJSON: nil
            )
        ]
        model.commandGrants = [
            SavedCommandGrant(
                token: "preview-grant", projectRoot: "/Users/demo/Projects/RelayOS",
                executable: "/usr/bin/git", workingDirectory: "/Users/demo/Projects/RelayOS",
                grantType: "always", familyKey: nil,
                scopePrefix: ["git", "status"], scopeFingerprint: nil,
                createdAt: now - 3600, expiresAt: nil
            )
        ]
        model.commandJobs = [
            CommandJobEntry(
                id: "preview-job", projectRoot: "/Users/demo/Projects/RelayOS",
                workingDirectory: "/Users/demo/Projects/RelayOS", executableName: "swift test",
                status: "running", createdAt: now - 75, finishedAt: nil,
                exitCode: nil, outputBytes: 512, errorReason: nil,
                cancelRequested: 0, sessionID: "sample-session"
            )
        ]
        model.selectedCommandJobID = "preview-job"
        model.commandJobOutput = "Building RelayOS…\nTest Suite started\nAll 24 tests passed."
        return model
    }
}

struct PreviewPageFrame<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(title).font(.system(size: 30, weight: .semibold))
                content
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(36)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: 930, height: 710)
    }
}
#endif
