import SwiftUI

struct SettingsCollapsibleCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @State private var isExpanded: Bool
    @State private var isHovered: Bool = false
    let content: Content

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        if let subtitle = subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color(white: 0.55))
                        }
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(white: 0.6))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(isHovered ? Color(white: 0.17) : Color(red: 0.14, green: 0.14, blue: 0.15))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            if isExpanded {
                Rectangle()
                    .fill(Color(white: 0.18))
                    .frame(height: 1)

                VStack(spacing: 0) {
                    content
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(red: 0.14, green: 0.14, blue: 0.15))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color(white: 0.19), lineWidth: 1)
        )
    }
}
