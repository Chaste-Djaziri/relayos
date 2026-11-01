// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/CommandPermissionsView.swift
import SwiftUI

struct CommandPermissionsView: View {
    @ObservedObject var model: BridgeModel
    @State private var query = ""
    @State private var expandedGroups: Set<String> = []
    @State private var pendingRevocation: SavedCommandGrant?
    @State private var confirmCleanup = false

    private struct GrantGroup: Identifiable {
        let id: String
        let projectRoot: String
        let commandName: String
        let grants: [SavedCommandGrant]
    }

    private var filtered: [SavedCommandGrant] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return model.commandGrants }
        return model.commandGrants.filter {
            [$0.scopeTitle, $0.projectRoot, $0.workingDirectory, $0.executable,
             $0.scopeFingerprint ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(value) }
        }
    }

    private var groups: [GrantGroup] {
        Dictionary(grouping: filtered, by: \.groupingKey)
            .map { (key, grants) in
                GrantGroup(
                    id: key,
                    projectRoot: grants[0].projectRoot,
                    commandName: grants[0].commandName,
                    grants: grants.sorted { $0.createdAt > $1.createdAt }
                )
            }
            .sorted {
                $0.commandName == $1.commandName
                    ? $0.projectRoot < $1.projectRoot
                    : $0.commandName < $1.commandName
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command Permissions").font(.title2.bold())
                    Text("Locally approved commands, grouped by executable and project.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.refreshCommandGrants()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }.disabled(model.commandGrantsBusy)
            }

            HStack {
                Text("\(model.commandGrants.count) saved approvals across \(groups.count) groups")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.commandGrantDuplicateCount > 0 {
                    Button("Remove \(model.commandGrantDuplicateCount) duplicates") {
                        confirmCleanup = true
                    }
                    .disabled(model.commandGrantsBusy)
                }
            }

            TextField("Search commands, scope or projects", text: $query)
                .textFieldStyle(.roundedBorder)

            if model.commandGrantsBusy {
                ProgressView("Loading permissions…")
            }
            if let error = model.commandGrantsError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

            if filtered.isEmpty && !model.commandGrantsBusy {
                ContentUnavailableView(
                    "No saved command permissions",
                    systemImage: "checkmark.shield",
                    description: Text(query.isEmpty
                        ? "Approve a reusable command locally to see it here."
                        : "No approved commands match this search.")
                )
            }

            ForEach(groups) { group in
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedGroups.contains(group.id) },
                        set: { expanded in
                            if expanded { expandedGroups.insert(group.id) }
                            else { expandedGroups.remove(group.id) }
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(group.grants) { grant in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(grant.scopeTitle).font(.subheadline.weight(.medium))
                                        .textSelection(.enabled)
                                    Text("\(grant.durationTitle) · \(grant.scopeDetails)")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if grant.workingDirectory != grant.projectRoot {
                                        Text("Working directory: \(grant.workingDirectory)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let expires = grant.expiresAt {
                                        Text("Expires: \(Date(timeIntervalSince1970: expires).formatted())")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 8)
                                Button("Revoke", role: .destructive) {
                                    pendingRevocation = grant
                                }
                                .disabled(model.commandGrantsBusy)
                            }
                            Divider()
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal")
                        Text(group.commandName).font(.headline)
                        Text("· \(group.grants.count) approvals")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .help(group.projectRoot)
                }
                .padding(12)
                .background(.quaternary.opacity(0.30), in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomLeading) {
                    Text(group.projectRoot)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 12)
                        .offset(y: 9)
                }
                .padding(.bottom, 12)
            }

            Text("Similar-looking exact commands can have different arguments. A short fingerprint distinguishes them without retaining command-line secrets. Cleanup only removes identical effective scopes; broader access still requires local approval.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .onAppear { model.refreshCommandGrants() }
        .confirmationDialog(
            "Revoke command permission?",
            isPresented: Binding(
                get: { pendingRevocation != nil },
                set: { if !$0 { pendingRevocation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Revoke permission", role: .destructive) {
                if let grant = pendingRevocation { model.revokeCommandGrant(grant.id) }
                pendingRevocation = nil
            }
            Button("Cancel", role: .cancel) { pendingRevocation = nil }
        } message: {
            if let grant = pendingRevocation {
                Text("Revoke \(grant.scopeTitle) in \(grant.projectRoot)? Future commands matching this permission will require approval again.")
            }
        }
        .confirmationDialog(
            "Remove identical saved approvals?",
            isPresented: $confirmCleanup,
            titleVisibility: .visible
        ) {
            Button("Remove duplicates", role: .destructive) {
                model.cleanupDuplicateCommandGrants()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only identical command scopes within the same project, working directory and approval duration will be merged. Distinct exact commands and separate coding sessions remain intact.")
        }
    }
}
