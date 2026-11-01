import SwiftUI

struct DiffView: View {
    let diff: String

    private struct DiffLine: Identifiable {
        let id: Int
        let text: String
        let type: LineType

        enum LineType {
            case fileHeader, hunkHeader, addition, deletion, context
        }

        var foregroundColor: Color {
            switch type {
            case .fileHeader: return Color(white: 0.70)
            case .hunkHeader: return Color(red: 0.55, green: 0.75, blue: 0.95)
            case .addition: return Color(red: 0.40, green: 0.88, blue: 0.50)
            case .deletion: return Color(red: 0.95, green: 0.45, blue: 0.45)
            case .context: return Color(white: 0.80)
            }
        }

        var backgroundColor: Color {
            switch type {
            case .fileHeader: return Color(white: 0.16)
            case .hunkHeader: return Color(red: 0.15, green: 0.25, blue: 0.35).opacity(0.4)
            case .addition: return Color(red: 0.15, green: 0.45, blue: 0.20).opacity(0.25)
            case .deletion: return Color(red: 0.50, green: 0.15, blue: 0.15).opacity(0.25)
            case .context: return Color.clear
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
                            .foregroundStyle(line.foregroundColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 1.5)
                    .background(line.backgroundColor)
                    .cornerRadius(2)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 280)
        .background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 6))
        .textSelection(.enabled)
    }
}
