import SwiftUI

struct SettingsCardRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let showDivider: Bool
    let trailing: Trailing

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

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                    if let subtitle = subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color(white: 0.55))
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
                    .fill(Color(white: 0.18))
                    .frame(height: 1)
                    .padding(.leading, 16)
            }
        }
    }
}
