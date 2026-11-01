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

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(backgroundView)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch style {
        case .primary:
            isHovered ? Color.blue.opacity(0.85) : Color.blue
        case .secondary:
            isHovered ? Color(white: 0.25) : Color(white: 0.19)
        case .destructive:
            isHovered ? Color.red.opacity(0.85) : Color(red: 0.72, green: 0.16, blue: 0.16)
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary:
            return Color.blue.opacity(0.6)
        case .secondary:
            return isHovered ? Color(white: 0.36) : Color(white: 0.26)
        case .destructive:
            return Color.red.opacity(0.6)
        }
    }
}
