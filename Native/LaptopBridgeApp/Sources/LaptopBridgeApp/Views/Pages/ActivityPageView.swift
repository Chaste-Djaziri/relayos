import SwiftUI
import AppKit

struct ActivityHistoryView: View {
    @ObservedObject var model: BridgeModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage(RelayOSTheme.reduceMotionKey) private var reduceMotion = false
    @State private var search = ""
    @State private var selectedActivity: ApprovalActivityEntry? = nil

    private var theme: ThemeColors {
        RelayOSTheme.colors(colorScheme)
    }

    private var filteredActivity: [ApprovalActivityEntry] {
        guard !search.isEmpty else { return model.approvalActivity }
        return model.approvalActivity.filter {
            [$0.kind, $0.target, $0.decision, $0.summaryTitle, $0.summarySubtitle]
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        Group {
            if let event = selectedActivity {
                activityDetailView(event)
            } else {
                activityListView
            }
        }
        .onAppear {
            model.refreshApprovalActivity(search: search)
        }
    }

    private var activityListView: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                    TextField("Search activity by command, target, or decision", text: $search)
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
                    model.refreshApprovalActivity(search: search)
                }
            }

            if filteredActivity.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 38))
                        .foregroundStyle(theme.textSecondary)
                    Text("No activity recorded")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text("Approved, denied, and executed actions will appear here with exact summaries, execution times, and exit codes.")
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
                SettingsCard(title: "Activity Log (\(filteredActivity.count))") {
                    ForEach(Array(filteredActivity.enumerated()), id: \.element.id) { index, event in
                        Button {
                            if reduceMotion || systemReduceMotion {
                                selectedActivity = event
                            } else {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    selectedActivity = event
                                }
                            }
                        } label: {
                            ActivitySummaryRow(
                                event: event,
                                showDivider: index < filteredActivity.count - 1
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func activityDetailView(_ event: ApprovalActivityEntry) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Button {
                    if reduceMotion {
                        selectedActivity = nil
                    } else {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            selectedActivity = nil
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("All Activity")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        colorScheme == .dark ? Color(white: 0.18) : Color(white: 0.90),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .foregroundStyle(theme.textPrimary)
                }
                .buttonStyle(.plain)

                Spacer()

                StatusBadge(
                    text: event.decision.capitalized,
                    status: event.decision == "denied" ? .offline : (event.decision == "expired" ? .warning : .healthy)
                )
            }

            if let details = event.details, let diff = details.diff, !diff.isEmpty {
                SettingsCard(title: "Code Changes & Diff") {
                    SettingsCardRow(
                        title: details.path ?? "File Diff",
                        subtitle: "\(details.linesAdded ?? 0) lines added, \(details.linesRemoved ?? 0) lines removed"
                    ) {
                        HStack(spacing: 8) {
                            if let added = details.linesAdded, added > 0 {
                                Text("+\(added)")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color(red: 0.40, green: 0.88, blue: 0.50))
                            }
                            if let removed = details.linesRemoved, removed > 0 {
                                Text("-\(removed)")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.45))
                            }
                            SettingsButton(title: "Copy Diff", icon: "doc.on.doc", style: .secondary) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(diff, forType: .string)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        DiffView(diff: diff)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
            }

            if let details = event.details, (details.command != nil || details.argv != nil) {
                let cmd = details.command ?? details.argv?.joined(separator: " ") ?? ""
                SettingsCard(title: "Exact Command Execution") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Command")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.textSecondary)
                            Spacer()
                            SettingsButton(title: "Copy Command", icon: "doc.on.doc", style: .secondary) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(cmd, forType: .string)
                            }
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(cmd)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(theme.codeText)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .background(theme.codeBackground, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(theme.cardBorder, lineWidth: 1)
                        )
                        .textSelection(.enabled)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 12)

                    if let dir = details.workingDirectory ?? event.parsedProjectDirectory {
                        SettingsCardRow(
                            title: "Working Directory",
                            subtitle: dir,
                            showDivider: false
                        ) {
                            SettingsButton(title: "Copy Path", icon: "doc.on.doc", style: .secondary) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(dir, forType: .string)
                            }
                        }
                    }
                }
            }

            if let details = event.details, let stdout = details.stdout, !stdout.isEmpty {
                SettingsCard(title: "Standard Output") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Output Preview")
                                .font(.system(size: 11.5))
                                .foregroundStyle(theme.textSecondary)
                            Spacer()
                            SettingsButton(title: "Copy Output", icon: "doc.on.doc", style: .secondary) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(stdout, forType: .string)
                            }
                        }

                        ScrollView(.vertical, showsIndicators: true) {
                            Text(stdout)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(theme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        .frame(maxHeight: 180)
                        .background(theme.codeBackground, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(theme.cardBorder, lineWidth: 1)
                        )
                        .textSelection(.enabled)
                    }
                    .padding(14)
                }
            }

            if let details = event.details, let stderr = details.stderr, !stderr.isEmpty {
                SettingsCard(title: "Standard Error") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Error Output")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.red.opacity(0.8))
                            Spacer()
                            SettingsButton(title: "Copy Error", icon: "doc.on.doc", style: .secondary) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(stderr, forType: .string)
                            }
                        }

                        ScrollView(.vertical, showsIndicators: true) {
                            Text(stderr)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color(red: 1.0, green: 0.5, blue: 0.5))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        .frame(maxHeight: 180)
                        .background(Color(red: 0.25, green: 0.08, blue: 0.08).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.red.opacity(0.4), lineWidth: 1)
                        )
                        .textSelection(.enabled)
                    }
                    .padding(14)
                }
            }

            SettingsCard(title: "Activity Summary") {
                SettingsCardRow(
                    title: "Event",
                    subtitle: event.summaryTitle
                ) {
                    HStack(spacing: 6) {
                        Image(systemName: event.systemIcon)
                            .font(.system(size: 12))
                            .foregroundStyle(.blue)
                        Text(event.kind)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.codeText)
                    }
                }

                SettingsCardRow(
                    title: "Decision & Outcome",
                    subtitle: "Recorded authorization result"
                ) {
                    StatusBadge(
                        text: event.decision.capitalized,
                        status: event.decision == "denied" ? .offline : (event.decision == "expired" ? .warning : .healthy)
                    )
                }

                SettingsCardRow(
                    title: "Timestamp",
                    subtitle: "Exact time event was logged on this Mac"
                ) {
                    Text(Date(timeIntervalSince1970: event.recordedAt).formatted(date: .abbreviated, time: .standard))
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textPrimary)
                }

                if let duration = event.formattedDuration {
                    SettingsCardRow(
                        title: "Duration",
                        subtitle: "Total execution elapsed time"
                    ) {
                        Text(duration)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(theme.textPrimary)
                    }
                }

                if let exit = event.formattedExitCode {
                    SettingsCardRow(
                        title: "Exit Status",
                        subtitle: event.exitCode == 0 ? "Process terminated cleanly" : "Process exited with error code",
                        showDivider: false
                    ) {
                        StatusBadge(
                            text: exit,
                            status: event.exitCode == 0 ? .healthy : .offline
                        )
                    }
                }
            }

            SettingsCard(title: "Target & Execution Context") {
                SettingsCardRow(
                    title: "Target identifier",
                    subtitle: "Resource or process requested by client"
                ) {
                    HStack(spacing: 8) {
                        Text(event.target)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                        SettingsButton(title: "Copy", icon: "doc.on.doc", style: .secondary) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(event.target, forType: .string)
                        }
                    }
                }

                if let dir = event.parsedProjectDirectory {
                    SettingsCardRow(
                        title: "Project Directory",
                        subtitle: dir
                    ) {
                        SettingsButton(title: "Copy Path", icon: "doc.on.doc", style: .secondary) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(dir, forType: .string)
                        }
                    }
                }

                if let exec = event.parsedExecutable {
                    SettingsCardRow(
                        title: "Executable",
                        subtitle: exec,
                        showDivider: false
                    ) {
                        Text(URL(fileURLWithPath: exec).lastPathComponent)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.textPrimary)
                    }
                }
            }

            SettingsCard(title: "Audit & Security Record") {
                SettingsCardRow(
                    title: "Record ID",
                    subtitle: "Unique monotonic database entry identifier"
                ) {
                    Text("#\(event.id)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                }

                SettingsCardRow(
                    title: "Authorization Boundary",
                    subtitle: "Locally enforced and recorded in RelayOS SQLite database. Client tool calls cannot bypass local audit records.",
                    showDivider: false
                ) {
                    StatusBadge(text: "Enforced locally", status: .healthy)
                }
            }
        }
    }
}

typealias ActivityPageView = ActivityHistoryView
