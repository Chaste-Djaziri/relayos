import SwiftUI

struct ActivitySummaryRow: View {
    let event: ApprovalActivityEntry
    let showDivider: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private var theme: ThemeColors {
        RelayOSTheme.colors(colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(colorScheme == .dark ? Color(white: 0.20) : Color(white: 0.90))
                        .frame(width: 32, height: 32)
                    Image(systemName: event.systemIcon)
                        .font(.system(size: 13))
                        .foregroundStyle(event.decision == "denied" ? Color.red : theme.textPrimary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(event.summaryTitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(theme.textPrimary)

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
                            .background(
                                colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.92),
                                in: RoundedRectangle(cornerRadius: 4)
                            )
                        }

                        Text(Date(timeIntervalSince1970: event.recordedAt).formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textSecondary)
                    }

                    Text(event.summarySubtitle)
                        .font(.system(size: 11.5, design: event.details?.command != nil ? .monospaced : .default))
                        .foregroundStyle(theme.textSecondary)
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
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                isHovered
                    ? (colorScheme == .dark ? Color(white: 0.17) : Color(white: 0.94))
                    : Color.clear
            )
            .contentShape(Rectangle())

            if showDivider {
                Rectangle()
                    .fill(theme.cardDivider)
                    .frame(height: 1)
                    .padding(.leading, 16)
            }
        }
        .onHover { isHovered = $0 }
    }
}
