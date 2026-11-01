import SwiftUI

struct TerminalJobRow: View {
    let job: CommandJobEntry
    let isSelected: Bool
    let onToggleOutput: () -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(RelayOSTheme.fontSizeKey) private var userFontSize = 14.0
    @State private var isHovered = false

    private var theme: ThemeColors {
        RelayOSTheme.colors(colorScheme)
    }

    private var scale: CGFloat {
        RelayOSTheme.scale(userFontSize)
    }

    private var statusBadge: some View {
        Group {
            if job.cancelRequested != 0 {
                StatusBadge(text: "Cancelling…", status: .offline)
            } else if job.status == "running" {
                StatusBadge(text: "Running", status: .healthy)
            } else if job.status == "queued" {
                StatusBadge(text: "Queued", status: .warning)
            } else if job.status == "cancelled" {
                StatusBadge(text: "Cancelled", status: .offline)
            } else if let exitCode = job.exitCode {
                StatusBadge(
                    text: "Exit \(exitCode)",
                    status: exitCode == 0 ? .healthy : .offline
                )
            } else {
                StatusBadge(text: job.status.capitalized, status: .offline)
            }
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Process status indicator box
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(job.active ? Color.green.opacity(0.12) : (colorScheme == .dark ? Color(white: 0.18) : Color(white: 0.88)))
                    .frame(width: max(34, 34 * scale), height: max(34, 34 * scale))

                Image(systemName: job.active ? "terminal.fill" : "terminal")
                    .font(.system(size: 14 * scale, weight: .semibold))
                    .foregroundStyle(job.active ? Color.green : theme.textSecondary)
            }

            // Job metadata
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(job.executableName)
                        .font(.system(size: 13.5 * scale, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.textPrimary)

                    statusBadge

                    if job.outputBytes > 0 {
                        Text("\(job.outputBytes) bytes")
                            .font(.system(size: 11 * scale, design: .monospaced))
                            .foregroundStyle(theme.textSecondary)
                    }

                    Spacer()
                }

                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 10 * scale))
                        Text(job.projectRoot)
                            .font(.system(size: 11 * scale, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(theme.textSecondary)

                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10 * scale))
                        Text(Date(timeIntervalSince1970: job.createdAt).formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11 * scale))
                    }
                    .foregroundStyle(theme.textSecondary)
                }

                if let reason = job.errorReason, !reason.isEmpty {
                    Text(reason)
                        .font(.system(size: 11 * scale))
                        .foregroundStyle(Color.red)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            // Actions
            HStack(spacing: 8) {
                SettingsButton(
                    title: isSelected ? "Hide Output" : "View Output",
                    icon: "terminal",
                    style: isSelected ? .primary : .secondary
                ) {
                    onToggleOutput()
                }

                if job.active {
                    SettingsButton(
                        title: "Cancel",
                        icon: "xmark.circle",
                        style: .destructive
                    ) {
                        onCancel()
                    }
                    .disabled(job.cancelRequested != 0)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            isHovered
                ? (colorScheme == .dark ? Color(white: 0.16) : Color(white: 0.94))
                : Color.clear
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
