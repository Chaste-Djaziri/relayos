import SwiftUI

struct DiffView: View {
    let diff: String

    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    private struct DiffLine: Identifiable {
        let id: Int
        let text: String
        let type: LineType

        enum LineType {
            case fileHeader, hunkHeader, addition, deletion, context
        }

        func foregroundColor(isDark: Bool) -> Color {
            switch type {
            case .fileHeader:
                return isDark ? Color(white: 0.70) : Color(white: 0.40)
            case .hunkHeader:
                return isDark ? Color(red: 0.55, green: 0.75, blue: 0.95) : Color(red: 0.10, green: 0.40, blue: 0.75)
            case .addition:
                return isDark ? Color(red: 0.40, green: 0.88, blue: 0.50) : Color(red: 0.12, green: 0.55, blue: 0.20)
            case .deletion:
                return isDark ? Color(red: 0.95, green: 0.45, blue: 0.45) : Color(red: 0.80, green: 0.18, blue: 0.18)
            case .context:
                return isDark ? Color(white: 0.80) : Color(white: 0.20)
            }
        }

        func backgroundColor(isDark: Bool) -> Color {
            switch type {
            case .fileHeader:
                return isDark ? Color(white: 0.16) : Color(white: 0.90)
            case .hunkHeader:
                return Color.blue.opacity(isDark ? 0.25 : 0.10)
            case .addition:
                return Color.green.opacity(isDark ? 0.22 : 0.12)
            case .deletion:
                return Color.red.opacity(isDark ? 0.22 : 0.12)
            case .context:
                return Color.clear
            }
        }
    }

    private var parsedLines: [DiffLine] {
        diff.components(separatedBy: "\n").enumerated().map { index, line in
            let type: DiffLine.LineType
            if line.hasPrefix("+++") || line.hasPrefix("---") {
                type = .fileHeader
            } else if line.hasPrefix("@@") {
                type = .hunkHeader
            } else if line.hasPrefix("+") {
                type = .addition
            } else if line.hasPrefix("-") {
                type = .deletion
            } else {
                type = .context
            }
            return DiffLine(id: index, text: line, type: type)
        }
    }

    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(parsedLines) { line in
                    HStack(spacing: 0) {
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(line.foregroundColor(isDark: isDark))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 1.5)
                    .background(line.backgroundColor(isDark: isDark))
                    .cornerRadius(2)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 280)
        .background(
            isDark ? Color(white: 0.10) : Color(white: 0.95),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isDark ? Color(white: 0.18) : Color(white: 0.86), lineWidth: 1)
        )
        .textSelection(.enabled)
    }
}
