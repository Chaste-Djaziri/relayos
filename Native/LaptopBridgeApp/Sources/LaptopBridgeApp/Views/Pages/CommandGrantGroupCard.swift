import SwiftUI

struct CommandGrantGroup: Identifiable {
    let id: String
    let projectRoot: String
    let commandName: String
    let grants: [SavedCommandGrant]
}

struct CommandGrantGroupCard: View {
    let group: CommandGrantGroup
    let onRevokeGrant: (SavedCommandGrant) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(RelayOSTheme.fontSizeKey) private var userFontSize = 14.0
    @AppStorage(RelayOSTheme.accentKey) private var accentName = "blue"
    @AppStorage(RelayOSTheme.reduceMotionKey) private var reduceMotion = false
    @State private var isExpanded = true
    @State private var isHeaderHovered = false

    private var theme: ThemeColors {
        RelayOSTheme.colors(colorScheme)
    }

    private var accentColor: Color {
        RelayOSTheme.accent(accentName)
    }

    private var scale: CGFloat {
        RelayOSTheme.scale(userFontSize)
    }

    private var iconName: String {
        switch group.commandName.lowercased() {
        case "git":
            return "arrow.triangle.branch"
        case "npm", "pnpm", "yarn", "bun":
            return "shippingbox.fill"
        case "python", "python3", "pytest":
            return "chevron.left.forwardslash.chevron.right"
        case "swift":
            return "swift"
        case "docker":
            return "ferry.fill"
        case "cargo", "rustc":
            return "gearshape.2.fill"
        default:
            return "terminal.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if reduceMotion {
                    isExpanded.toggle()
                } else {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(accentColor.opacity(0.15))
                            .frame(width: max(32, 32 * scale), height: max(32, 32 * scale))

                        Image(systemName: iconName)
                            .font(.system(size: 14 * scale, weight: .semibold))
                            .foregroundStyle(accentColor)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(group.commandName)
                                .font(.system(size: 14 * scale, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)

                            StatusBadge(
                                text: "\(group.grants.count) \(group.grants.count == 1 ? "approval" : "approvals")",
                                status: .healthy
                            )
                        }

                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(.system(size: 10 * scale))
                            Text(group.projectRoot)
                                .font(.system(size: 11.5 * scale, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(theme.textSecondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11 * scale, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    isHeaderHovered
                        ? (colorScheme == .dark ? Color(white: 0.17) : Color(white: 0.94))
                        : theme.cardBackground
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHeaderHovered = $0 }

            if isExpanded {
                Rectangle()
                    .fill(theme.cardDivider)
                    .frame(height: 1)

                VStack(spacing: 0) {
                    ForEach(Array(group.grants.enumerated()), id: \.element.id) { index, grant in
                        CommandGrantItemRow(grant: grant) {
                            onRevokeGrant(grant)
                        }

                        if index < group.grants.count - 1 {
                            Rectangle()
                                .fill(theme.cardDivider)
                                .frame(height: 1)
                                .padding(.leading, 16)
                        }
                    }
                }
                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(theme.cardBorder, lineWidth: 1)
        )
        .shadow(
            color: colorScheme == .light ? Color.black.opacity(0.035) : Color.clear,
            radius: 3, x: 0, y: 1
        )
    }
}
