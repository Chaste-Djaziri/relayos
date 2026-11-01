import SwiftUI

struct SettingsCard<Content: View>: View {
    let title: String?
    let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(white: 0.60))
                    .padding(.leading, 2)
            }
            VStack(spacing: 0) {
                content
            }
            .background(Color(red: 0.14, green: 0.14, blue: 0.15))
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(Color(white: 0.19), lineWidth: 1)
            )
        }
    }
}
