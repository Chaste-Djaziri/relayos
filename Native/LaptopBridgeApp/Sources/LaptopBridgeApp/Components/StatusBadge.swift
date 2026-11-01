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

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(dotColor.opacity(0.12), in: Capsule())
    }

    private var dotColor: Color {
        switch status {
        case .healthy: return .green
        case .warning: return .orange
        case .offline: return .red
        case .neutral: return Color(white: 0.6)
        }
    }

    private var textColor: Color {
        switch status {
        case .healthy: return Color(red: 0.45, green: 0.88, blue: 0.45)
        case .warning: return Color(red: 1.0, green: 0.72, blue: 0.32)
        case .offline: return Color(red: 1.0, green: 0.45, blue: 0.45)
        case .neutral: return Color(white: 0.75)
        }
    }
}
