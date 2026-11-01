// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/CommandJobsView.swift
import SwiftUI
import Combine

struct CommandJobsView: View {
    @ObservedObject var model: BridgeModel
    @State private var filter = ""
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var matches: [CommandJobEntry] {
        filter.isEmpty ? model.commandJobs : model.commandJobs.filter {
            [$0.executableName, $0.projectRoot, $0.status]
                .contains { $0.localizedCaseInsensitiveContains(filter) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Terminal Jobs").font(.title2.bold())
                    Text("Approved background commands · output remains in the MCP server process.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.refreshCommandJobs()
                    model.refreshCommandJobOutput()
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            TextField("Filter by command, project or status", text: $filter)
                .textFieldStyle(.roundedBorder)
            if let error = model.commandJobError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).font(.caption)
            }
            if matches.isEmpty {
                ContentUnavailableView("No terminal jobs", systemImage: "terminal",
                    description: Text("An approved background command will appear here."))
            }
            ForEach(matches) { job in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(job.executableName).font(.headline)
                        Text(job.projectRoot).font(.caption)
                            .foregroundStyle(.secondary).lineLimit(1)
                        Text("\(job.status.capitalized) · \(Date(timeIntervalSince1970: job.createdAt).formatted())")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Output") { model.selectCommandJob(job.id) }
                    if job.active {
                        Button("Cancel", role: .destructive) { model.cancelCommandJob(job.id) }
                            .disabled(job.cancelRequested != 0)
                    }
                }
                Divider()
            }
            if let selectedID = model.selectedCommandJobID {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Incremental output").font(.headline)
                        Spacer()
                        Text(String(selectedID.prefix(10))).font(.caption).foregroundStyle(.secondary)
                    }
                    ScrollView {
                        Text(model.commandJobOutput.isEmpty ? "No output yet." : model.commandJobOutput)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 130, maxHeight: 230)
                    .padding(8)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Text("No shell is invoked. Jobs must be authorized through the same local approvals as ordinary commands. Output is available only while the owning MCP server retains it; metadata survives restarts.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .onAppear { model.refreshCommandJobs() }
        .onReceive(ticker) { _ in
            model.refreshCommandJobs()
            if model.selectedCommandJobID != nil { model.refreshCommandJobOutput() }
        }
    }
}
