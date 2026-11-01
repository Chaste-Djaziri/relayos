import SwiftUI

struct SettingsCardRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let showDivider: Bool
    let trailing: Trailing

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(RelayOSTheme.fontSizeKey) private var userFontSize = 14.0

    init(
        title: String,
        subtitle: String? = nil,
        showDivider: Bool = true,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.showDivider = showDivider
        self.trailing = trailing()
    }

    private var theme: ThemeColors {
        RelayOSTheme.colors(colorScheme)
    }

    private var scale: CGFloat {
        RelayOSTheme.scale(userFontSize)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13 * scale, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                    if let subtitle = subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11.5 * scale))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 16)
                trailing
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if showDivider {
                Rectangle()
                    .fill(theme.cardDivider)
                    .frame(height: 1)
                    .padding(.leading, 16)
            }
        }
    }
}
