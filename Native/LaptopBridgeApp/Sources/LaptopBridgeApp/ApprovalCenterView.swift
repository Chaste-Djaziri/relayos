// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/ApprovalCenterView.swift
import SwiftUI

// MARK: - Approval Requests Page (Pending Inbox)

struct ApprovalCenterView: View {
    @ObservedObject var model: BridgeModel
    @State private var search = ""

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
                        .foregroundStyle(Color(white: 0.5))
                    TextField("Search pending requests", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(white: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 8))

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
                        .foregroundStyle(Color(white: 0.45))
                    Text("No pending approvals")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("New local command and MCP connection requests from AI clients will appear here for your review.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.55))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
                .background(Color(red: 0.14, green: 0.14, blue: 0.15))
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color(white: 0.19), lineWidth: 1))
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
                                .foregroundStyle(Color(white: 0.7))
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

// MARK: - Activity History Page (Audit Trail)

struct ActivityHistoryView: View {
    @ObservedObject var model: BridgeModel
    @State private var search = ""

    private var filteredActivity: [ApprovalActivityEntry] {
        guard !search.isEmpty else { return model.approvalActivity }
        return model.approvalActivity.filter {
            [$0.kind, $0.target, $0.decision]
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.5))
                    TextField("Search activity by command, target, or decision", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(white: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 8))

                SettingsButton(title: "Refresh", icon: "arrow.clockwise", style: .secondary) {
                    model.refreshApprovalActivity(search: search)
                }
            }

            if filteredActivity.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 38))
                        .foregroundStyle(Color(white: 0.45))
                    Text("No activity recorded")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Approved, denied, and executed actions will appear here with timestamps and exit codes.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.55))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
                .background(Color(red: 0.14, green: 0.14, blue: 0.15))
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color(white: 0.19), lineWidth: 1))
            } else {
                SettingsCard(title: "Audit Trail (\(filteredActivity.count))") {
                    ForEach(Array(filteredActivity.enumerated()), id: \.element.id) { index, event in
                        SettingsCardRow(
                            title: "\(event.kind.replacingOccurrences(of: "_", with: " ").capitalized) · \(event.decision.capitalized)",
                            subtitle: "\(event.target) · \(Date(timeIntervalSince1970: event.recordedAt).formatted())",
                            showDivider: index < filteredActivity.count - 1
                        ) {
                            HStack(spacing: 8) {
                                if let code = event.exitCode {
                                    StatusBadge(
                                        text: "Exit \(code)",
                                        status: code == 0 ? .healthy : .offline
                                    )
                                }
                                StatusBadge(
                                    text: event.decision.capitalized,
                                    status: event.decision == "denied" ? .offline : .healthy
                                )
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            model.refreshApprovalActivity(search: search)
        }
    }
}
