import SwiftUI

enum SettingsButtonStyle {
    case primary
    case secondary
    case destructive
}

struct SettingsButton: View {
    let title: String
    var icon: String? = nil
    var style: SettingsButtonStyle = .secondary
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(RelayOSTheme.accentKey) private var accent = "blue"
    @AppStorage(RelayOSTheme.fontSizeKey) private var userFontSize = 14.0
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
            HStack(spacing: 6) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 11 * scale, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12 * scale, weight: .medium))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(backgroundView)
            .foregroundStyle(textColor)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var textColor: Color {
        switch style {
        case .primary, .destructive:
            return .white
        case .secondary:
            return theme.textPrimary
        }
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch style {
        case .primary:
            isHovered ? accentColor.opacity(0.85) : accentColor
        case .secondary:
            if colorScheme == .dark {
                isHovered ? Color(white: 0.25) : Color(white: 0.19)
            } else {
                isHovered ? Color(white: 0.88) : Color(white: 0.94)
            }
        case .destructive:
            isHovered ? Color.red.opacity(0.85) : Color(red: 0.78, green: 0.18, blue: 0.18)
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary:
            return accentColor.opacity(0.7)
        case .secondary:
            if colorScheme == .dark {
                return isHovered ? Color(white: 0.36) : Color(white: 0.26)
            } else {
                return isHovered ? Color(white: 0.72) : Color(white: 0.82)
            }
        case .destructive:
            return Color.red.opacity(0.6)
        }
    }
}
