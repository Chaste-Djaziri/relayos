// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/ApprovalCenterView.swift
import SwiftUI

struct ApprovalCenterView: View {
    @ObservedObject var model: BridgeModel
    @State private var showingHistory = false
    @State private var search = ""

    init(model: BridgeModel, initialShowingHistory: Bool = false) {
        self.model = model
        self._showingHistory = State(initialValue: initialShowingHistory)
    }

    private var visibleInbox: [ApprovalInboxItem] {
        guard !search.isEmpty else { return model.approvalInbox }
        return model.approvalInbox.filter {
            [$0.title, $0.kind, $0.target, $0.context.cwd ?? "", $0.argv.joined(separator: " ")]
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Approval Center").font(.title2.bold())
                    Text("Decisions are enforced locally and recorded in RelayOS.")
                        .foregroundStyle(.secondary).font(.caption)
                }
                Spacer()
                Button {
                    model.refreshApprovalInbox()
                    model.refreshApprovalActivity(search: search)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }

            Picker("View", selection: $showingHistory) {
                Text("Inbox (\(model.approvalInbox.count))").tag(false)
                Text("Activity").tag(true)
            }.pickerStyle(.segmented)
            TextField("Search commands, projects, clients or activity", text: $search)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if showingHistory { model.refreshApprovalActivity(search: search) } }

            if let error = model.approvalCenterError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).font(.caption)
            }

            if showingHistory {
                if model.approvalActivity.isEmpty {
                    ContentUnavailableView("No activity recorded", systemImage: "clock.arrow.circlepath",
                        description: Text("Approved, denied, executed and failed actions appear here."))
                }
                ForEach(model.approvalActivity) { event in
                    HStack(alignment: .top) {
                        Image(systemName: event.decision == "denied" ? "xmark.shield" : "checkmark.shield")
                            .foregroundColor(event.decision == "denied" ? Color.red : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(event.kind.replacingOccurrences(of: "_", with: " ")) · \(event.decision)")
                                .font(.callout.weight(.medium))
                            Text(event.target).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2).textSelection(.enabled)
                            Text(Date(timeIntervalSince1970: event.recordedAt).formatted())
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let code = event.exitCode {
                            Text("Exit \(code)").font(.caption)
                                .foregroundColor(code == 0 ? Color.secondary : Color.red)
                        }
                    }
                    Divider()
                }
            } else {
                if visibleInbox.isEmpty {
                    ContentUnavailableView("No pending approvals", systemImage: "checkmark.shield",
                        description: Text("New local command and MCP connection requests will appear here."))
                }
                ForEach(visibleInbox) { item in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: item.isOAuth ? "link" : "terminal")
                                Text(item.title).font(.headline)
                                Spacer()
                                Text(item.isOAuth ? "Connection" : "Local request")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(item.target).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled).lineLimit(2)
                            if !item.argv.isEmpty {
                                Text(item.argv.joined(separator: " "))
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            if let cwd = item.context.cwd {
                                Text("Directory: \(cwd)").font(.caption)
                                    .foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Text(item.scopeDescription).font(.caption).foregroundStyle(.secondary)
                            Text("Expires: \(Date(timeIntervalSince1970: item.expiresAt).formatted())")
                                .font(.caption2).foregroundStyle(.secondary)
                            HStack {
                                Button(item.isOAuth ? "Approve" : "Once") {
                                    model.decideApproval(item, decision: "once")
                                }.buttonStyle(.borderedProminent)
                                if !item.isOAuth {
                                    Button("Session") { model.decideApproval(item, decision: "session") }
                                    Button("Always") { model.decideApproval(item, decision: "persistent") }
                                }
                                Button("Deny", role: .destructive) {
                                    model.decideApproval(item, decision: "deny")
                                }
                                Spacer()
                            }
                            .disabled(item.isExpired || model.approvalDecisionInFlight != nil)
                        }
                    }
                }
            }
        }
        .padding()
        .onAppear {
            model.refreshApprovalInbox()
            model.refreshApprovalActivity()
        }
        .onChange(of: showingHistory) { _, value in
            if value { model.refreshApprovalActivity(search: search) }
        }
    }
}
