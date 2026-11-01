import SwiftUI

struct SettingsCard<Content: View>: View {
    let title: String?
    let content: Content

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(RelayOSTheme.fontSizeKey) private var userFontSize = 14.0

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    private var theme: ThemeColors {
        RelayOSTheme.colors(colorScheme)
    }

    private var scale: CGFloat {
        RelayOSTheme.scale(userFontSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = title {
                Text(title)
                    .font(.system(size: 13 * scale, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.leading, 2)
            }
            VStack(spacing: 0) {
                content
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
}
