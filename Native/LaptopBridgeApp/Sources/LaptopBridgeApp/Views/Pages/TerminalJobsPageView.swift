import SwiftUI

struct CommandJobsView: View {
    @ObservedObject var model: BridgeModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(RelayOSTheme.fontSizeKey) private var userFontSize = 14.0
    @AppStorage(RelayOSTheme.accentKey) private var accentName = "blue"

    @State private var filter = ""
    @AppStorage(CommandJobCompletionNotification.enabledKey) private var notifyOnFinish = false

    private var theme: ThemeColors {
        RelayOSTheme.colors(colorScheme)
    }

    private var accentColor: Color {
        RelayOSTheme.accent(accentName)
    }

    private var scale: CGFloat {
        RelayOSTheme.scale(userFontSize)
    }

    private var matches: [CommandJobEntry] {
        let text = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return model.commandJobs }
        return model.commandJobs.filter {
            [$0.executableName, $0.projectRoot, $0.workingDirectory, $0.status, $0.sessionID]
                .contains { $0.localizedCaseInsensitiveContains(text) }
        }
    }

    private var activeCount: Int {
        model.commandJobs.filter { $0.active }.count
    }

    private var selectedJob: CommandJobEntry? {
        guard let id = model.selectedCommandJobID else { return nil }
        return model.commandJobs.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header description and actions
            HStack(alignment: .center, spacing: 12) {
                Text("Approved background commands · output streams locally via the MCP server process.")
                    .font(.system(size: 13 * scale))
                    .foregroundStyle(theme.textSecondary)

                Spacer()

                SettingsButton(
                    title: "Refresh",
                    icon: "arrow.clockwise",
                    style: .secondary
                ) {
                    model.refreshCommandJobs()
                    if model.selectedCommandJobID != nil {
                        model.refreshCommandJobOutput()
                    }
                }
            }

            HStack(spacing: 10) {
                Toggle("Notify when a job finishes", isOn: $notifyOnFinish)
                    .toggleStyle(.checkbox)
                    .onChange(of: notifyOnFinish) { _, newValue in
                        if newValue { ApprovalArrivalNotification.requestPermission() }
                    }
                Spacer()
                Text("Updates automatically every 2 seconds")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12 * scale))
                    .foregroundStyle(theme.textSecondary)

                TextField("Filter by executable, project, status, or session ID", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12 * scale))
                    .foregroundStyle(theme.textPrimary)

                if !filter.isEmpty {
                    Button {
                        filter = ""
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
            if let error = model.commandJobError {
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
            if !model.commandJobs.isEmpty {
                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11 * scale))
                            .foregroundStyle(activeCount > 0 ? Color.green : theme.textSecondary)
                        Text("\(activeCount) active \(activeCount == 1 ? "job" : "jobs")")
                            .font(.system(size: 12 * scale, weight: .medium))
                            .foregroundStyle(theme.textPrimary)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 11 * scale))
                            .foregroundStyle(theme.textSecondary)
                        Text("\(model.commandJobs.count) total recorded")
                            .font(.system(size: 12 * scale))
                            .foregroundStyle(theme.textSecondary)
                    }

                    Spacer()

                    StatusBadge(
                        text: activeCount > 0 ? "Monitoring" : "Idle",
                        status: activeCount > 0 ? .healthy : .offline
                    )
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.cardBorder, lineWidth: 1))
            }

            // Selected job console
            if let job = selectedJob {
                TerminalOutputConsole(
                    job: job,
                    output: model.commandJobOutput,
                    receivedBytes: model.commandJobStdoutOffset + model.commandJobStderrOffset,
                    followLive: $model.commandJobFollowEnabled
                ) {
                    model.clearSelectedCommandJob()
                }
            }

            // Jobs list or empty state
            if matches.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.system(size: 38))
                        .foregroundStyle(theme.textSecondary)
                    Text(filter.isEmpty ? "No terminal jobs" : "No matching jobs found")
                        .font(.system(size: 15 * scale, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(filter.isEmpty
                        ? "Long-running commands executed by paired AI clients (such as dev servers or test runners) run in the background and stream their output here."
                        : "No jobs match \"\(filter)\". Try searching by executable name, directory path, or session ID.")
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
                SettingsCard(title: "Background Terminal Jobs (\(matches.count))") {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, job in
                        TerminalJobRow(
                            job: job,
                            isSelected: model.selectedCommandJobID == job.id,
                            onToggleOutput: {
                                if model.selectedCommandJobID == job.id {
                                    model.clearSelectedCommandJob()
                                } else {
                                    model.selectCommandJob(job.id)
                                }
                            },
                            onCancel: {
                                model.cancelCommandJob(job.id)
                            },
                            canCancel: !model.isDevelopmentClient
                        )

                        if index < matches.count - 1 {
                            Rectangle()
                                .fill(theme.cardDivider)
                                .frame(height: 1)
                                .padding(.leading, 16)
                        }
                    }
                }
            }

            // Process isolation explanation card
            SettingsCard(title: "Process Isolation & Security") {
                SettingsCardRow(
                    title: "Direct Process Execution",
                    subtitle: "Python MCP executes the exact locally approved executable and arguments without invoking a shell."
                ) {
                    StatusBadge(text: "Locally approved", status: .healthy)
                }

                SettingsCardRow(
                    title: "Stream Retention",
                    subtitle: "Output stays in bounded temporary files in the MCP server; job metadata survives restart, but previous output buffers do not.",
                    showDivider: false
                ) {
                    StatusBadge(text: "Temporary buffers", status: .warning)
                }
            }
        }
        .onAppear {
            guard !model.isPreview else { return }
            // Polling belongs to the app lifecycle, not this view. Returning
            // to this page still performs an immediate refresh.
            model.startCommandJobMonitoring()
            model.refreshCommandJobs()
            if model.selectedCommandJobID != nil { model.refreshCommandJobOutput() }
        }
    }
}

#if DEBUG
#Preview("Terminal jobs") {
    let model = BridgeModel.preview()
    PreviewPageFrame("Terminal jobs") {
        CommandJobsView(model: model)
    }
}
#endif
