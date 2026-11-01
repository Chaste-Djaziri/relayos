import SwiftUI
import AppKit

struct ApprovalCenterView: View {
    @ObservedObject var model: BridgeModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var search = ""

    private var theme: ThemeColors {
        RelayOSTheme.colors(colorScheme)
    }

    private var visibleInbox: [ApprovalInboxItem] {
        guard !search.isEmpty else { return model.approvalInbox }
        return model.approvalInbox.filter {
            [$0.title, $0.kind, $0.target, $0.context.cwd ?? "", $0.argv.joined(separator: " ")]
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                    TextField("Search pending requests", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textPrimary)
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(theme.sidebarSearchBackground, in: RoundedRectangle(cornerRadius: 8))

                SettingsButton(title: "Refresh", icon: "arrow.clockwise", style: .secondary) {
                    model.refreshApprovalInbox()
                }
            }

            if let error = model.approvalCenterError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if visibleInbox.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 38))
                        .foregroundStyle(theme.textSecondary)
                    Text("No pending approvals")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text("New local command and MCP connection requests from AI clients will appear here for your review.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
                .background(theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(theme.cardBorder, lineWidth: 1))
            } else {
                ForEach(visibleInbox) { item in
                    SettingsCard(title: item.isOAuth ? "OAuth Connection Request" : "Command Execution Request") {
                        SettingsCardRow(
                            title: item.title,
                            subtitle: item.scopeDescription
                        ) {
                            StatusBadge(
                                text: item.isOAuth ? "Connection" : "Local request",
                                status: .warning
                            )
                        }

                        SettingsCardRow(
                            title: "Target & Working Directory",
                            subtitle: item.context.cwd != nil ? "Dir: \(item.context.cwd!)" : item.target
                        ) {
                            Text(item.target)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(theme.codeText)
                                .lineLimit(1)
                        }

                        if !item.argv.isEmpty {
                            SettingsCardRow(
                                title: "Command Arguments",
                                subtitle: item.argv.joined(separator: " ")
                            ) {
                                EmptyView()
                            }
                        }

                        SettingsCardRow(
                            title: "Expires",
                            subtitle: Date(timeIntervalSince1970: item.expiresAt).formatted(),
                            showDivider: false
                        ) {
                            HStack(spacing: 8) {
                                SettingsButton(
                                    title: item.isOAuth ? "Approve" : "Once",
                                    style: .primary
                                ) {
                                    model.decideApproval(item, decision: "once")
                                }

                                if !item.isOAuth {
                                    SettingsButton(title: "Session", style: .secondary) {
                                        model.decideApproval(item, decision: "session")
                                    }
                                    SettingsButton(title: "Always", style: .secondary) {
                                        model.decideApproval(item, decision: "persistent")
                                    }
                                }

                                SettingsButton(title: "Deny", style: .destructive) {
                                    model.decideApproval(item, decision: "deny")
                                }
                            }
                            .disabled(item.isExpired || model.approvalDecisionInFlight != nil)
                        }
                    }
                }
            }
        }
        .onAppear {
            model.refreshApprovalInbox()
        }
    }
}

typealias ApprovalsPageView = ApprovalCenterView
