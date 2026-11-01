import SwiftUI

struct StatusBadge: View {
    enum StatusType {
        case healthy
        case warning
        case offline
        case neutral
    }

    let text: String
    var status: StatusType = .neutral

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(RelayOSTheme.fontSizeKey) private var userFontSize = 14.0

    private var scale: CGFloat {
        RelayOSTheme.scale(userFontSize)
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11.5 * scale, weight: .medium))
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(dotColor.opacity(colorScheme == .dark ? 0.14 : 0.10), in: Capsule())
    }

    private var dotColor: Color {
        switch status {
        case .healthy: return Color(red: 0.20, green: 0.75, blue: 0.35)
        case .warning: return Color(red: 1.0, green: 0.60, blue: 0.15)
        case .offline: return Color(red: 0.95, green: 0.30, blue: 0.30)
        case .neutral: return colorScheme == .dark ? Color(white: 0.6) : Color(white: 0.45)
        }
    }

    private var textColor: Color {
        if colorScheme == .dark {
            switch status {
            case .healthy: return Color(red: 0.45, green: 0.88, blue: 0.45)
            case .warning: return Color(red: 1.0, green: 0.72, blue: 0.32)
            case .offline: return Color(red: 1.0, green: 0.45, blue: 0.45)
            case .neutral: return Color(white: 0.75)
            }
        } else {
            switch status {
            case .healthy: return Color(red: 0.12, green: 0.55, blue: 0.20)
            case .warning: return Color(red: 0.75, green: 0.45, blue: 0.05)
            case .offline: return Color(red: 0.78, green: 0.18, blue: 0.18)
            case .neutral: return Color(white: 0.35)
            }
        }
    }
}
