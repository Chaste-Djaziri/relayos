// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Services/BridgeModel+CommandJobs.swift
import Foundation

/// Backward compatibility for older installed hybrid bundles that do not
/// yet expose /control/command-jobs. Runs the existing *bundled* list/cancel
/// helper off the main thread, without starting or restarting an MCP server.
private enum LegacyCommandJobControl {
    static func run(helper: String, workingDirectory: URL?,
                    arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["-m", "laptop_bridge.approvals"] + arguments
        process.currentDirectoryURL = workingDirectory
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Read stdout before waiting; stderr cannot fill a separate pipe.
        // Warnings must not corrupt the JSON returned by the helper.
        let data = try stdout.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let description = String(decoding: data.prefix(1000), as: UTF8.self)
            throw NSError(domain: "RelayOSLegacyJobs", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: description.isEmpty
                            ? "Job helper failed" : description])
        }
        return data
    }
}

/// The local control API is restricted to loopback and the same secret used by
/// RelayOS health checks. Polling never creates, approves, or launches a job.
extension BridgeModel {
    func startCommandJobMonitoring() {
        guard !isPreview, !isSwiftOnly, commandJobMonitoringTimer == nil else { return }
        refreshCommandJobs()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshCommandJobs()
                if self.selectedCommandJobID != nil { self.refreshCommandJobOutput() }
            }
        }
        timer.resume()
        commandJobMonitoringTimer = timer
    }

    func stopCommandJobMonitoring() {
        commandJobMonitoringTimer?.cancel()
        commandJobMonitoringTimer = nil
    }

    func refreshCommandJobs() {
        guard !isPreview, !isSwiftOnly, !commandJobPollInFlight else { return }
        guard let token = MCPHealthMonitor.readLocalControlToken(),
              let url = URL(string: "http://127.0.0.1:8765/control/command-jobs?limit=100")
        else {
            commandJobError = "Local control token unavailable. Check the RelayOS MCP server."
            return
        }
        commandJobPollInFlight = true
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(token, forHTTPHeaderField: "x-relayos-control-token")
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.commandJobPollInFlight = false }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode
                let jobs: [CommandJobEntry]
                if statusCode == 200 {
                    jobs = try JSONDecoder().decode(CommandJobListResponse.self, from: data).jobs
                } else if statusCode == 404, let helper = self.approvalExecutable() {
                    let directory = helper.contains("/Contents/Resources/Runtime/")
                        ? FileManager.default.homeDirectoryForCurrentUser
                        : DevelopmentRuntimeLocator.projectRoot()
                    let legacyData = try await Task.detached(priority: .utility) {
                        try LegacyCommandJobControl.run(
                            helper: helper, workingDirectory: directory,
                            arguments: ["list-command-jobs"])
                    }.value
                    jobs = try JSONDecoder().decode([CommandJobEntry].self, from: legacyData)
                } else {
                    throw URLError(.badServerResponse)
                }
                let oldJobs = Dictionary(uniqueKeysWithValues: self.commandJobs.map { ($0.id, $0) })
                self.commandJobs = jobs
                self.commandJobError = nil
                if self.commandJobListInitialized {
                    // Only report transitions that happened during monitoring,
                    // not old completed jobs loaded at app launch.
                    for job in jobs {
                        guard let previous = oldJobs[job.id], previous.active,
                              !job.active, previous.status != job.status else { continue }
                        CommandJobCompletionNotification.deliver(job)
                    }
                }
                self.commandJobListInitialized = true
            } catch {
                self.commandJobError = "Unable to monitor background jobs: \(error.localizedDescription)"
            }
        }
    }

    func selectCommandJob(_ id: String) {
        guard selectedCommandJobID != id else { return }
        selectedCommandJobID = id
        commandJobStdoutOffset = 0
        commandJobStderrOffset = 0
        commandJobOutput = ""
        commandJobError = nil
        refreshCommandJobOutput()
    }

    func clearSelectedCommandJob() {
        selectedCommandJobID = nil
        commandJobOutput = ""
        commandJobStdoutOffset = 0
        commandJobStderrOffset = 0
    }

    func refreshCommandJobOutput() {
        guard !isPreview, !isSwiftOnly,
              let jobID = selectedCommandJobID,
              !commandOutputPollInFlight,
              let token = MCPHealthMonitor.readLocalControlToken(),
              let encodedID = jobID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return }
        var components = URLComponents(string: "http://127.0.0.1:8765/control/command-job-output/\(encodedID)")!
        let stdoutOffset = commandJobStdoutOffset
        let stderrOffset = commandJobStderrOffset
        components.queryItems = [
            URLQueryItem(name: "stdout_offset", value: String(stdoutOffset)),
            URLQueryItem(name: "stderr_offset", value: String(stderrOffset))
        ]
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(token, forHTTPHeaderField: "x-relayos-control-token")
        commandOutputPollInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.commandOutputPollInFlight = false }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let output = try JSONDecoder().decode(CommandJobOutput.self, from: data)
                guard self.selectedCommandJobID == jobID else { return }
                // Offsets are byte counts, never the length of a Swift String.
                self.commandJobStdoutOffset = output.stdoutOffset
                self.commandJobStderrOffset = output.stderrOffset
                let newText = CommandJobOutputFormatter.append(
                    existing: self.commandJobOutput, stdout: output.stdout, stderr: output.stderr)
                self.commandJobOutput = newText
                if output.outputUnavailable && self.commandJobOutput.isEmpty {
                    self.commandJobOutput = "Output unavailable after MCP server restart. Job metadata remains in history."
                }
                self.commandJobError = nil
            } catch {
                guard self.selectedCommandJobID == jobID else { return }
                self.commandJobError = "Unable to follow job output: \(error.localizedDescription)"
            }
        }
    }

    func cancelCommandJob(_ jobID: String) {
        guard !isPreview, !isDevelopmentClient,
              let token = MCPHealthMonitor.readLocalControlToken(),
              let url = URL(string: "http://127.0.0.1:8765/control/command-jobs/cancel"),
              let body = try? JSONSerialization.data(withJSONObject: ["job_id": jobID])
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "x-relayos-control-token")
        request.httpBody = body
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode
                if code == 404, let helper = self.approvalExecutable() {
                    let directory = helper.contains("/Contents/Resources/Runtime/")
                        ? FileManager.default.homeDirectoryForCurrentUser
                        : DevelopmentRuntimeLocator.projectRoot()
                    _ = try await Task.detached(priority: .userInitiated) {
                        try LegacyCommandJobControl.run(
                            helper: helper, workingDirectory: directory,
                            arguments: ["cancel-command-job", jobID])
                    }.value
                } else {
                    guard code == 200,
                          let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          reply["cancellation_requested"] as? Bool == true else {
                        throw URLError(.badServerResponse)
                    }
                }
                self.commandJobError = nil
                self.refreshCommandJobs()
            } catch {
                self.commandJobError = "Job cancellation failed: \(error.localizedDescription)"
            }
        }
    }
}
