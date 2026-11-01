import SwiftUI

struct CommandPermissionsView: View {
    @ObservedObject var model: BridgeModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(RelayOSTheme.fontSizeKey) private var userFontSize = 14.0
    @AppStorage(RelayOSTheme.accentKey) private var accentName = "blue"

    @State private var query = ""
    @State private var pendingRevocation: SavedCommandGrant?
    @State private var confirmCleanup = false

    private var theme: ThemeColors {
        RelayOSTheme.colors(colorScheme)
    }

    private var accentColor: Color {
        RelayOSTheme.accent(accentName)
    }

    private var scale: CGFloat {
        RelayOSTheme.scale(userFontSize)
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

    private var groups: [CommandGrantGroup] {
        Dictionary(grouping: filtered, by: \.groupingKey)
            .map { (key, grants) in
                CommandGrantGroup(
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
        VStack(alignment: .leading, spacing: 20) {
            // Header description and actions
            HStack(alignment: .center, spacing: 12) {
                Text("Locally approved commands, grouped by executable and project directory.")
                    .font(.system(size: 13 * scale))
                    .foregroundStyle(theme.textSecondary)

                Spacer()

                if model.commandGrantDuplicateCount > 0 {
                    SettingsButton(
                        title: "Clean \(model.commandGrantDuplicateCount) duplicates",
                        icon: "sparkles",
                        style: .secondary
                    ) {
                        confirmCleanup = true
                    }
                    .disabled(model.commandGrantsBusy)
                }

                SettingsButton(
                    title: "Refresh",
                    icon: "arrow.clockwise",
                    style: .secondary
                ) {
                    model.refreshCommandGrants()
                }
                .disabled(model.commandGrantsBusy)
            }

            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12 * scale))
                    .foregroundStyle(theme.textSecondary)

                TextField("Search commands, scope, executable, or projects", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12 * scale))
                    .foregroundStyle(theme.textPrimary)

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11 * scale))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: max(32, 32 * scale))
            .background(theme.sidebarSearchBackground, in: RoundedRectangle(cornerRadius: 8))

            // Error notice
            if let error = model.commandGrantsError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.red)
                    Text(error)
                        .font(.system(size: 12 * scale))
                        .foregroundStyle(Color.red)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            // Summary stats pill row
            if !model.commandGrants.isEmpty {
                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 11 * scale))
                            .foregroundStyle(accentColor)
                        Text("\(model.commandGrants.count) saved \(model.commandGrants.count == 1 ? "approval" : "approvals")")
                            .font(.system(size: 12 * scale, weight: .medium))
                            .foregroundStyle(theme.textPrimary)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11 * scale))
                            .foregroundStyle(theme.textSecondary)
                        Text("\(groups.count) project \(groups.count == 1 ? "group" : "groups")")
                            .font(.system(size: 12 * scale))
                            .foregroundStyle(theme.textSecondary)
                    }

                    Spacer()

                    StatusBadge(text: "Enforced locally", status: .healthy)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.cardBorder, lineWidth: 1))
            }

            // Main content
            if model.commandGrantsBusy && model.commandGrants.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.9)
                    Text("Loading command permissions…")
                        .font(.system(size: 13 * scale))
                        .foregroundStyle(theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
                .background(theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(theme.cardBorder, lineWidth: 1))
            } else if filtered.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 38))
                        .foregroundStyle(theme.textSecondary)
                    Text(query.isEmpty ? "No saved command permissions" : "No matching command permissions")
                        .font(.system(size: 15 * scale, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(query.isEmpty
                        ? "Commands approved with 'Always' or 'For session' are saved locally here so you can review or revoke them anytime."
                        : "No saved command approvals match \"\(query)\". Try searching by executable name, directory path, or fingerprint.")
                        .font(.system(size: 12 * scale))
                        .foregroundStyle(theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
                .background(theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(theme.cardBorder, lineWidth: 1))
            } else {
                VStack(spacing: 14) {
                    ForEach(groups) { group in
                        CommandGrantGroupCard(group: group) { grant in
                            pendingRevocation = grant
                        }
                    }
                }
            }

            // Security explanation card
            SettingsCard(title: "Security & Argument Fingerprints") {
                SettingsCardRow(
                    title: "Local SQLite Enforcement",
                    subtitle: "Saved approvals are cryptographically bound to the executable and project folder. AI clients cannot elevate privileges or run unauthorized executables."
                ) {
                    StatusBadge(text: "Active", status: .healthy)
                }

                SettingsCardRow(
                    title: "Privacy & Argument Fingerprints",
                    subtitle: "Exact commands store a cryptographic hash of parameters to recognize re-runs without recording passwords, API keys, or proprietary variables.",
                    showDivider: false
                ) {
                    StatusBadge(text: "Zero-leak", status: .healthy)
                }
            }
        }
        .onAppear {
            model.refreshCommandGrants()
        }
        .confirmationDialog(
            "Revoke command permission?",
            isPresented: Binding(
                get: { pendingRevocation != nil },
                set: { if !$0 { pendingRevocation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Revoke permission", role: .destructive) {
                if let grant = pendingRevocation {
                    model.revokeCommandGrant(grant.id)
                }
                pendingRevocation = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRevocation = nil
            }
        } message: {
            if let grant = pendingRevocation {
                Text("Revoke \"\(grant.scopeTitle)\" in \(grant.projectRoot)? Next time an AI agent invokes this command, it will require manual authorization.")
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
            Text("Only identical command scopes within the same project, working directory, and duration will be merged. Distinct commands and session limits remain intact.")
        }
    }
}
