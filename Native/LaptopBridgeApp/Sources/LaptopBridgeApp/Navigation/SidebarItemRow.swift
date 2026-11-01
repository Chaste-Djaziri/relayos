import SwiftUI

struct SidebarItemRow: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    var badgeCount: Int = 0
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(RelayOSTheme.accentKey) private var accent = "blue"
    @AppStorage(RelayOSTheme.fontSizeKey) private var userFontSize = 14.0
    @AppStorage(RelayOSTheme.reduceMotionKey) private var reduceMotion = false
    @State private var isHovered = false

    private var theme: ThemeColors {
        RelayOSTheme.colors(colorScheme)
    }

    private var scale: CGFloat {
        RelayOSTheme.scale(userFontSize)
    }

    private var accentColor: Color {
        RelayOSTheme.accent(accent)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13 * scale))
                    .frame(width: 18 * scale, height: 18 * scale)
                    .foregroundStyle(iconColor)

                Text(title)
                    .font(.system(size: 13 * scale, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(textColor)
                    .lineLimit(1)

                Spacer()

                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 10 * scale, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(accentColor, in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .frame(height: max(28, 30 * scale))
            .background(backgroundShape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isSelected)
    }

    private var iconColor: Color {
        if isSelected {
            return accentColor
        }
        if isHovered {
            return theme.textPrimary
        }
        return theme.textSecondary
    }

    private var textColor: Color {
        if isSelected {
            return theme.textPrimary
        }
        if isHovered {
            return theme.textPrimary
        }
        return colorScheme == .dark ? Color(white: 0.82) : Color(white: 0.28)
    }

    private var backgroundShape: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(
                isSelected
                    ? accentColor.opacity(colorScheme == .dark ? 0.24 : 0.18)
                    : (isHovered
                        ? (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                        : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isSelected ? accentColor.opacity(colorScheme == .dark ? 0.45 : 0.35) : Color.clear,
                        lineWidth: 1
                    )
            )
    }
}
