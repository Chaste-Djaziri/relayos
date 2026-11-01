import SwiftUI
import AppKit

struct TerminalOutputConsole: View {
    let job: CommandJobEntry
    let output: String
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(RelayOSTheme.fontSizeKey) private var userFontSize = 14.0
    @State private var copiedNotice = false

    private var theme: ThemeColors {
        RelayOSTheme.colors(colorScheme)
    }

    private var scale: CGFloat {
        RelayOSTheme.scale(userFontSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // macOS terminal window titlebar
            HStack(spacing: 8) {
                // Window dots
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(red: 1.0, green: 0.38, blue: 0.35))
                        .frame(width: 10, height: 10)
                    Circle()
                        .fill(Color(red: 1.0, green: 0.74, blue: 0.22))
                        .frame(width: 10, height: 10)
                    Circle()
                        .fill(Color(red: 0.16, green: 0.78, blue: 0.30))
                        .frame(width: 10, height: 10)
                }
                .padding(.trailing, 6)

                Text(job.executableName)
                    .font(.system(size: 12 * scale, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)

                Text("·")
                    .foregroundStyle(Color(white: 0.5))

                Text("Console Output")
                    .font(.system(size: 11.5 * scale, weight: .medium))
                    .foregroundStyle(Color(white: 0.7))

                if job.active {
                    StatusBadge(text: "Live streaming", status: .healthy)
                } else if let exitCode = job.exitCode {
                    StatusBadge(
                        text: "Exit \(exitCode)",
                        status: exitCode == 0 ? .healthy : .offline
                    )
                }

                Spacer()

                if copiedNotice {
                    Text("Copied to clipboard!")
                        .font(.system(size: 11 * scale))
                        .foregroundStyle(Color(red: 0.40, green: 0.88, blue: 0.50))
                }

                SettingsButton(title: "Copy", icon: "doc.on.doc", style: .secondary) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                    withAnimation {
                        copiedNotice = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation {
                            copiedNotice = false
                        }
                    }
                }

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11 * scale, weight: .semibold))
                        .foregroundStyle(Color(white: 0.7))
                        .padding(6)
                        .background(Color(white: 0.20), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(red: 0.12, green: 0.12, blue: 0.13))

            // Console output text area
            ScrollView(.vertical) {
                Text(output.isEmpty ? "Waiting for output from process…" : output)
                    .font(.system(size: 11 * scale, design: .monospaced))
                    .foregroundStyle(output.isEmpty ? Color(white: 0.45) : Color(red: 0.85, green: 0.92, blue: 0.88))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 160, maxHeight: 280)
            .background(Color(red: 0.07, green: 0.07, blue: 0.08))

            // Terminal status footer
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 10 * scale))
                    Text("\(job.outputBytes) bytes received")
                        .font(.system(size: 10.5 * scale, design: .monospaced))
                }
                .foregroundStyle(Color(white: 0.55))

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 10 * scale))
                    Text(job.workingDirectory)
                        .font(.system(size: 10.5 * scale, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(Color(white: 0.55))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color(red: 0.10, green: 0.10, blue: 0.11))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.22), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.35), radius: 6, x: 0, y: 3)
    }
}

#if DEBUG
#Preview("Terminal output") {
    let model = BridgeModel.preview()
    TerminalOutputConsole(job: model.commandJobs[0],
                          output: model.commandJobOutput, onClose: {})
        .allowsHitTesting(false).frame(width: 760).padding()
}
#endif
