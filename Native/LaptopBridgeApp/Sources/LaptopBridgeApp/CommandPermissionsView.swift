// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/CommandPermissionsView.swift
import SwiftUI

struct CommandPermissionsView: View {
    @ObservedObject var model: BridgeModel
    @State private var query = ""
    @State private var pendingRevocation: SavedCommandGrant?

    private var filtered: [SavedCommandGrant] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return model.commandGrants }
        return model.commandGrants.filter {
            [$0.scopeTitle, $0.projectRoot, $0.workingDirectory, $0.executable]
                .contains { $0.localizedCaseInsensitiveContains(value) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command Permissions").font(.title2.bold())
                    Text("Review and revoke locally approved project commands.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.refreshCommandGrants()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }.disabled(model.commandGrantsBusy)
            }

            TextField("Search commands or projects", text: $query)
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

            ForEach(filtered) { grant in
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(grant.scopeTitle).font(.headline).textSelection(.enabled)
                                Text(grant.scopeDetails).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(grant.durationTitle)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Button("Revoke", role: .destructive) {
                                pendingRevocation = grant
                            }.disabled(model.commandGrantsBusy)
                        }
                        Divider()
                        LabeledContent("Project", value: grant.projectRoot)
                        LabeledContent("Working directory", value: grant.workingDirectory)
                        LabeledContent("Executable", value: grant.executable)
                        if let expires = grant.expiresAt {
                            LabeledContent("Expires", value: Date(timeIntervalSince1970: expires).formatted())
                        }
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                }
            }
            Text("To change an approved command scope, revoke it and approve a new request. Broader access is never granted automatically.")
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
    }
}
