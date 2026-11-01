// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/ApprovalCenterView.swift
import SwiftUI
import AppKit

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

// MARK: - Activity History Page (Audit Trail & Details)

struct ActivityHistoryView: View {
    @ObservedObject var model: BridgeModel
    @State private var search = ""
    @State private var selectedActivity: ApprovalActivityEntry? = nil

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
                    Text("Approved, denied, and executed actions will appear here with exact summaries, execution times, and exit codes.")
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
                SettingsCard(title: "Activity Log (\(filteredActivity.count))") {
                    ForEach(Array(filteredActivity.enumerated()), id: \.element.id) { index, event in
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                selectedActivity = event
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
                    withAnimation(.easeInOut(duration: 0.16)) {
                        selectedActivity = nil
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
                    .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)
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
                                .foregroundStyle(Color(white: 0.7))
                            Spacer()
                            SettingsButton(title: "Copy Command", icon: "doc.on.doc", style: .secondary) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(cmd, forType: .string)
                            }
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(cmd)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Color(red: 0.45, green: 0.80, blue: 1.0))
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 6))
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
                                .foregroundStyle(Color(white: 0.6))
                            Spacer()
                            SettingsButton(title: "Copy Output", icon: "doc.on.doc", style: .secondary) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(stdout, forType: .string)
                            }
                        }

                        ScrollView(.vertical, showsIndicators: true) {
                            Text(stdout)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color(white: 0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        .frame(maxHeight: 180)
                        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 6))
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
                            .foregroundStyle(Color(white: 0.7))
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
                        .foregroundStyle(Color(white: 0.8))
                }

                if let duration = event.formattedDuration {
                    SettingsCardRow(
                        title: "Duration",
                        subtitle: "Total execution elapsed time"
                    ) {
                        Text(duration)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white)
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
                            .foregroundStyle(Color(white: 0.8))
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
                            .foregroundStyle(.white)
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
                        .foregroundStyle(Color(white: 0.7))
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

struct DiffView: View {
    let diff: String

    private struct DiffLine: Identifiable {
        let id: Int
        let text: String
        let type: LineType

        enum LineType {
            case fileHeader, hunkHeader, addition, deletion, context
        }

        var foregroundColor: Color {
            switch type {
            case .fileHeader: return Color(white: 0.70)
            case .hunkHeader: return Color(red: 0.55, green: 0.75, blue: 0.95)
            case .addition: return Color(red: 0.40, green: 0.88, blue: 0.50)
            case .deletion: return Color(red: 0.95, green: 0.45, blue: 0.45)
            case .context: return Color(white: 0.80)
            }
        }

        var backgroundColor: Color {
            switch type {
            case .fileHeader: return Color(white: 0.16)
            case .hunkHeader: return Color(red: 0.15, green: 0.25, blue: 0.35).opacity(0.4)
            case .addition: return Color(red: 0.15, green: 0.45, blue: 0.20).opacity(0.25)
            case .deletion: return Color(red: 0.50, green: 0.15, blue: 0.15).opacity(0.25)
            case .context: return Color.clear
            }
        }
    }

    private var parsedLines: [DiffLine] {
        diff.components(separatedBy: "\n").enumerated().map { index, line in
            let type: DiffLine.LineType
            if line.hasPrefix("+++") || line.hasPrefix("---") {
                type = .fileHeader
            } else if line.hasPrefix("@@") {
                type = .hunkHeader
            } else if line.hasPrefix("+") {
                type = .addition
            } else if line.hasPrefix("-") {
                type = .deletion
            } else {
                type = .context
            }
            return DiffLine(id: index, text: line, type: type)
        }
    }

    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(parsedLines) { line in
                    HStack(spacing: 0) {
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(line.foregroundColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 1.5)
                    .background(line.backgroundColor)
                    .cornerRadius(2)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 280)
        .background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 6))
        .textSelection(.enabled)
    }
}

private struct ActivitySummaryRow: View {
    let event: ApprovalActivityEntry
    let showDivider: Bool
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(white: 0.20))
                        .frame(width: 32, height: 32)
                    Image(systemName: event.systemIcon)
                        .font(.system(size: 13))
                        .foregroundStyle(event.decision == "denied" ? Color.red : Color(white: 0.85))
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(event.summaryTitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)

                        if let details = event.details, (details.linesAdded != nil || details.linesRemoved != nil) {
                            HStack(spacing: 4) {
                                if let added = details.linesAdded, added > 0 {
                                    Text("+\(added)")
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color(red: 0.40, green: 0.88, blue: 0.50))
                                }
                                if let removed = details.linesRemoved, removed > 0 {
                                    Text("-\(removed)")
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.45))
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 4))
                        }

                        Text(Date(timeIntervalSince1970: event.recordedAt).formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11))
                            .foregroundStyle(Color(white: 0.45))
                    }

                    Text(event.summarySubtitle)
                        .font(.system(size: 11.5, design: event.details?.command != nil ? .monospaced : .default))
                        .foregroundStyle(Color(white: 0.55))
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    if let code = event.exitCode {
                        StatusBadge(
                            text: "Exit \(code)",
                            status: code == 0 ? .healthy : .offline
                        )
                    }

                    StatusBadge(
                        text: event.decision.capitalized,
                        status: event.decision == "denied" ? .offline : (event.decision == "expired" ? .warning : .healthy)
                    )

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(white: 0.40))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(isHovered ? Color(white: 0.17) : Color.clear)
            .contentShape(Rectangle())

            if showDivider {
                Rectangle()
                    .fill(Color(white: 0.18))
                    .frame(height: 1)
                    .padding(.leading, 16)
            }
        }
        .onHover { isHovered = $0 }
    }
}
