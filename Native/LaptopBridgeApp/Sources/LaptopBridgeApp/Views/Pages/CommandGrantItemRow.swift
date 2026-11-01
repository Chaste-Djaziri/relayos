import SwiftUI

struct CommandGrantItemRow: View {
    let grant: SavedCommandGrant
    let onRevoke: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(RelayOSTheme.fontSizeKey) private var userFontSize = 14.0
    @State private var isHovered = false

    private var theme: ThemeColors {
        RelayOSTheme.colors(colorScheme)
    }

    private var scale: CGFloat {
        RelayOSTheme.scale(userFontSize)
    }

    private var isExpired: Bool {
        grant.isExpired()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(grant.scopeTitle)
                        .font(.system(size: 13 * scale, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.codeText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.codeBackground, in: RoundedRectangle(cornerRadius: 5))

                    if isExpired {
                        StatusBadge(text: "Expired", status: .offline)
                    } else if grant.grantType == "always" {
                        StatusBadge(text: "Always allowed", status: .healthy)
                    } else {
                        StatusBadge(text: "Coding session", status: .warning)
                    }

                    Spacer()
                }

                Text(grant.scopeDetails)
                    .font(.system(size: 11.5 * scale))
                    .foregroundStyle(theme.textSecondary)

                HStack(spacing: 12) {
                    if grant.workingDirectory != grant.projectRoot {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(.system(size: 10 * scale))
                            Text(grant.workingDirectory)
                                .font(.system(size: 11 * scale, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(theme.textSecondary)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10 * scale))
                        Text("Granted \(Date(timeIntervalSince1970: grant.createdAt).formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11 * scale))
                    }
                    .foregroundStyle(theme.textSecondary)

                    if let expiresAt = grant.expiresAt {
                        HStack(spacing: 4) {
                            Image(systemName: "hourglass")
                                .font(.system(size: 10 * scale))
                            Text("Expires \(Date(timeIntervalSince1970: expiresAt).formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 11 * scale))
                        }
                        .foregroundStyle(isExpired ? Color.red.opacity(0.8) : theme.textSecondary)
                    }
                }
            }

            Spacer(minLength: 8)

            SettingsButton(title: "Revoke", icon: "trash", style: .destructive) {
                onRevoke()
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

#if DEBUG
#Preview("Command permission row") {
    CommandGrantItemRow(grant: BridgeModel.preview().commandGrants[0], onRevoke: {})
        .allowsHitTesting(false).frame(width: 760).padding()
}
#endif
