import SwiftUI

struct SettingsCollapsibleCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @State private var isExpanded: Bool
    @State private var isHovered: Bool = false
    let content: Content

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage(RelayOSTheme.fontSizeKey) private var userFontSize = 14.0
    @AppStorage(RelayOSTheme.reduceMotionKey) private var reduceMotion = false

    init(
        title: String,
        subtitle: String? = nil,
        initiallyExpanded: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self._isExpanded = State(initialValue: initiallyExpanded)
        self.content = content()
    }

    private var theme: ThemeColors {
        RelayOSTheme.colors(colorScheme)
    }

    private var scale: CGFloat {
        RelayOSTheme.scale(userFontSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if reduceMotion || systemReduceMotion {
                    isExpanded.toggle()
                } else {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13 * scale, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                        if let subtitle = subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 11.5 * scale))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11 * scale, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    isHovered
                        ? (colorScheme == .dark ? Color(white: 0.17) : Color(white: 0.94))
                        : theme.cardBackground
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            if isExpanded {
                Rectangle()
                    .fill(theme.cardDivider)
                    .frame(height: 1)

                VStack(spacing: 0) {
                    content
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
