// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Views/Pages/TerminalOutputConsole.swift
import SwiftUI
import AppKit

struct TerminalOutputConsole: View {
    let job: CommandJobEntry
    let output: String
    let receivedBytes: Int
    @Binding var followLive: Bool
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(RelayOSTheme.fontSizeKey) private var userFontSize = 14.0
    @State private var copiedNotice = false

    private var scale: CGFloat { RelayOSTheme.scale(userFontSize) }
    private var reportedPercent: Double? {
        CommandJobProgress.percentage(in: output)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(Color(red: 0.42, green: 0.86, blue: 0.58))
                Text(job.executableName)
                    .font(.system(size: 12 * scale, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 5)
                Label(job.active ? "Following job" : job.status.capitalized,
                      systemImage: job.active ? "waveform.path" : "checkmark.circle")
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(job.active ? .green : .gray)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                    copiedNotice = true
                } label: {
                    Label(copiedNotice ? "Copied" : "Copy", systemImage: "doc.on.doc")
                        .font(.system(size: 11 * scale))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.white)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .foregroundStyle(.white)
                        .padding(5)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close terminal output")
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(Color(red: 0.12, green: 0.12, blue: 0.13))

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Label(CommandJobProgress.elapsedLabel(job, at: context.date), systemImage: "clock")
                            .font(.system(size: 11 * scale, design: .monospaced))
                    }
                    Spacer()
                    if let percent = reportedPercent {
                        Text(String(format: "%.1f%% reported by command", percent))
                            .font(.system(size: 11 * scale, design: .monospaced))
                    } else {
                        Text(job.active ? "Progress available as output arrives" : job.status.capitalized)
                            .font(.system(size: 11 * scale))
                    }
                }
                .foregroundStyle(Color(white: 0.72))
                if let percent = reportedPercent {
                    ProgressView(value: percent, total: 100)
                        .progressViewStyle(.linear)
                        .tint(.green)
                        .accessibilityLabel("Command-reported progress")
                } else if job.active {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(.green)
                        .accessibilityLabel("Command running; completion percentage unavailable")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(red: 0.10, green: 0.10, blue: 0.11))

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    Text(output.isEmpty
                         ? (job.active ? "Waiting for the next stdout/stderr update…" : "No output recorded.")
                         : output)
                        .font(.system(size: 11.5 * scale, design: .monospaced))
                        .foregroundStyle(output.isEmpty ? Color(white: 0.52) : Color(red: 0.85, green: 0.92, blue: 0.88))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                    Color.clear.frame(height: 1).id("terminal-bottom")
                }
                .onAppear {
                    if followLive { proxy.scrollTo("terminal-bottom", anchor: .bottom) }
                }
                .onChange(of: output) { _, _ in
                    if followLive {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo("terminal-bottom", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: followLive) { _, enabled in
                    if enabled { proxy.scrollTo("terminal-bottom", anchor: .bottom) }
                }
            }
            .frame(minHeight: 195, maxHeight: 360)
            .background(Color(red: 0.07, green: 0.07, blue: 0.08))

            HStack(spacing: 12) {
                Label("\(receivedBytes) bytes streamed", systemImage: "arrow.down.circle")
                    .lineLimit(1)
                Spacer(minLength: 4)
                Toggle("Follow output", isOn: $followLive)
                    .toggleStyle(.checkbox)
                    .accessibilityHint("Automatically scroll to the newest terminal output")
            }
            .font(.system(size: 10.5 * scale))
            .foregroundStyle(Color(white: 0.72))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(red: 0.11, green: 0.11, blue: 0.12))
        }
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .stroke(Color(white: 0.22), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.23), radius: 5, y: 2)
    }
}

#if DEBUG
#Preview("Terminal output · Live") {
    let model = BridgeModel.preview()
    TerminalOutputConsole(job: model.commandJobs[0],
                          output: model.commandJobOutput,
                          receivedBytes: 512,
                          followLive: .constant(true), onClose: {})
        .frame(width: 760).padding()
}
#endif
